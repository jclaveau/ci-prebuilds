#!/usr/bin/env python3
"""Refuses an image whose compressed amd64 size grew past its published one by more than 5%.

    image-size-gate.py <build_tag> <allowances.tsv> <os>-<image>...

Each image's candidate is ghcr.io/jclaveau/<image>:<build_tag>, its baseline the published
build-chain image ghcr.io/jclaveau/<image>-sudoer:latest. A deliberate growth is accepted by a line
`<image>\t<max_mib>\t<reason>` in the allowances file, committed with the change that grows it.

Exists because nothing failed when the Stage B node layer went from 24 to 54 MiB compressed
(include/node alone was 58 MiB of OpenSSL headers for 21 platforms) and every consumer job paid
~10 s more pull for it.
"""
import json
import re
import subprocess
import sys

GROWTH_RATIO_LIMIT = 1.05
MIB = 1024 * 1024
REPORTED_GROWTH_BYTES = MIB // 10


def read_allowances(lines):
    allowance_by_image = {}
    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 3 or not fields[2].strip():
            raise ValueError(
                f"allowance line {line_number} is not <image>\\t<max_mib>\\t<reason>: {json.dumps(line)}"
            )
        image_name, max_mib, _reason = fields
        allowance_by_image[image_name] = float(max_mib)
    return allowance_by_image


def judge_image_size(image_name, candidate_layers, baseline_layers, allowance_mib):
    """Layers are [{"digest", "size", "created_by"}]. Returns (passed, report lines)."""
    candidate_bytes = sum(layer["size"] for layer in candidate_layers)
    candidate_mib = candidate_bytes / MIB
    if baseline_layers is None:
        return True, [f"{image_name}: {candidate_mib:.1f} MiB, no published baseline, first release"]
    baseline_mib = sum(layer["size"] for layer in baseline_layers) / MIB
    ceiling_mib = baseline_mib * GROWTH_RATIO_LIMIT
    report_lines = [
        f"{image_name}: {candidate_mib:.1f} vs {baseline_mib:.1f} MiB "
        f"({candidate_mib / baseline_mib:.3f}x), ceiling {ceiling_mib:.1f} MiB"
    ]
    if allowance_mib is not None:
        if allowance_mib <= ceiling_mib:
            report_lines.append(
                f"  allowance {allowance_mib:.1f} MiB is under the ratio ceiling: delete its line"
            )
        ceiling_mib = max(ceiling_mib, allowance_mib)
        report_lines[0] += f", allowance {allowance_mib:.1f} MiB"
    if candidate_mib <= ceiling_mib:
        return True, report_lines
    unmatched_baseline = {}
    for layer in baseline_layers:
        unmatched_baseline.setdefault(build_step_key(layer["created_by"]), layer)
    grown_lines, new_layers = [], []
    for layer in candidate_layers:
        baseline_layer = unmatched_baseline.pop(build_step_key(layer["created_by"]), None)
        if baseline_layer is None:
            new_layers.append(layer)
        elif layer["size"] - baseline_layer["size"] >= REPORTED_GROWTH_BYTES:
            grown_lines.append((layer["size"] - baseline_layer["size"], baseline_layer["size"], layer))
    report_lines.append("  same step, grown:")
    for growth_bytes, baseline_size, layer in sorted(grown_lines, key=lambda item: -item[0]):
        report_lines.append(
            f"    +{growth_bytes / MIB:.1f} MiB ({baseline_size / MIB:.1f} -> {layer['size'] / MIB:.1f})"
            f"  {step_summary(layer)}"
        )
    for heading, layers in (("  steps only in the candidate:", new_layers),
                            ("  steps only in the baseline:", list(unmatched_baseline.values()))):
        report_lines.append(heading)
        for layer in sorted(layers, key=lambda layer: -layer["size"]):
            if layer["size"] >= REPORTED_GROWTH_BYTES:
                report_lines.append(f"    {layer['size'] / MIB:.1f} MiB  {step_summary(layer)}")
    return False, report_lines


def step_summary(layer):
    return layer["created_by"].split("\n", 1)[0][:100]


def build_step_key(created_by):
    """The build step's command without its build-arg values, so a version bump still matches."""
    without_arg_count = re.sub(r"^RUN \|\d+ ", "RUN ", created_by)
    return re.sub(r"\b[A-Z][A-Z0-9_]*=\S+(?: \d+)*", "", without_arg_count).split("\n", 1)[0]


def inspect_layers(image_ref):
    """Returns the amd64 layers of image_ref, or None when the tag does not exist."""
    manifest_completed = subprocess.run(
        ["docker", "manifest", "inspect", "-v", image_ref], capture_output=True, text=True
    )
    if manifest_completed.returncode != 0:
        if "manifest unknown" in manifest_completed.stderr or "no such manifest" in manifest_completed.stderr:
            return None
        raise RuntimeError(
            f"manifest inspect {json.dumps(image_ref)} failed: {json.dumps(manifest_completed.stderr)}"
        )
    config_completed = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", image_ref, "--format", "{{json .Image}}"],
        capture_output=True, text=True, check=True,
    )
    return pair_layers_with_history(
        image_ref, json.loads(manifest_completed.stdout), json.loads(config_completed.stdout)
    )


def pair_layers_with_history(image_ref, manifest_entries, image_config):
    if isinstance(manifest_entries, dict):
        manifest_entries = [manifest_entries]
    amd64_entries = [
        entry for entry in manifest_entries
        if entry["Descriptor"].get("platform", {}).get("architecture", "amd64") == "amd64"
    ]
    if len(amd64_entries) != 1:
        raise RuntimeError(f"{json.dumps(image_ref)} has {len(amd64_entries)} amd64 manifests, not 1")
    manifest = amd64_entries[0].get("OCIManifest") or amd64_entries[0]["SchemaV2Manifest"]
    image_config = image_config.get("linux/amd64", image_config)
    layer_commands = [
        step.get("created_by", "") for step in image_config["history"] if not step.get("empty_layer")
    ]
    if len(layer_commands) != len(manifest["layers"]):
        raise RuntimeError(
            f"{json.dumps(image_ref)}: {len(manifest['layers'])} layers but "
            f"{len(layer_commands)} non-empty history steps"
        )
    return [
        {"digest": layer["digest"], "size": layer["size"], "created_by": command}
        for layer, command in zip(manifest["layers"], layer_commands)
    ]


def main(argv):
    build_tag, allowances_path, *image_names = argv
    with open(allowances_path) as allowances_file:
        allowance_by_image = read_allowances(allowances_file)
    failed_images = []
    for image_name in image_names:
        candidate_layers = inspect_layers(f"ghcr.io/jclaveau/{image_name}:{build_tag}")
        if candidate_layers is None:
            raise RuntimeError(f"candidate {json.dumps(image_name)}:{json.dumps(build_tag)} does not exist")
        baseline_layers = inspect_layers(f"ghcr.io/jclaveau/{image_name}-sudoer:latest")
        passed, report_lines = judge_image_size(
            image_name, candidate_layers, baseline_layers, allowance_by_image.get(image_name)
        )
        print("\n".join(report_lines))
        if not passed:
            failed_images.append(image_name)
            print(f"::error::{report_lines[0]} — shrink it, or accept it with a line in {allowances_path}")
    if failed_images:
        print(f"{len(failed_images)} image(s) over their size ceiling: {json.dumps(failed_images)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
