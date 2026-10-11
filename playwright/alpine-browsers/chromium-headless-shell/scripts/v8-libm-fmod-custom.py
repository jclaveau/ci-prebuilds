#!/usr/bin/env python3
"""Route V8's x64 floating-point modulus through libm-fmod-custom.

V8 on x64 emits an inline x87 `fprem` loop for JS `%` on doubles, in two
places: TurboFan's code generator and Maglev. arm64 instead calls
ExternalReference::mod_two_doubles_operation, i.e. Modulo() in utils.h. This
gives x64 the arm64 shape, and makes Modulo() call the gcc-built
libm-fmod-custom (renamed v8_libm_fmod_custom, so it never collides with the
fmod Rust's compiler_builtins links into chrome).

Every replacement must match exactly once, or the build stops here rather
than hours later.

Usage: v8-libm-fmod-custom.py <v8-dir> <libm-fmod-custom.s>
"""
import shutil
import sys

v8_dir, asm_path = sys.argv[1], sys.argv[2]


def replace_once(rel_path, old, new):
    path = f"{v8_dir}/{rel_path}"
    text = open(path).read()
    count = text.count(old)
    if count != 1:
        sys.exit(f"ERROR: {rel_path}: anchor matched {count} times, want 1:\n{old}")
    open(path, "w").write(text.replace(old, new))
    print(f"    patched {rel_path}")


def replace_block(rel_path, start, end, new):
    """Replace from `start` up to (not including) `end`."""
    path = f"{v8_dir}/{rel_path}"
    text = open(path).read()
    if text.count(start) != 1:
        sys.exit(f"ERROR: {rel_path}: block start matched {text.count(start)} times")
    head, tail = text.split(start)
    if end not in tail:
        sys.exit(f"ERROR: {rel_path}: block end not found after start")
    open(path, "w").write(head + new + tail[tail.index(end):])
    print(f"    patched {rel_path}")


shutil.copy(asm_path, f"{v8_dir}/src/base/libm-fmod-custom.S")

replace_once(
    "BUILD.gn",
    'v8_component("v8_libbase") {\n  sources = [\n',
    'v8_component("v8_libbase") {\n  sources = [\n'
    '    "src/base/libm-fmod-custom.S",\n',
)

replace_once(
    "src/utils/utils.h",
    "inline double Modulo(double x, double y) {\n",
    'extern "C" double v8_libm_fmod_custom(double x, double y);\n\n'
    "inline double Modulo(double x, double y) {\n",
)
replace_once(
    "src/utils/utils.h",
    "#else\n  return std::fmod(x, y);\n#endif\n}\n",
    "#else\n  return v8_libm_fmod_custom(x, y);\n#endif\n}\n",
)

replace_once(
    "src/compiler/backend/x64/instruction-selector-x64.cc",
    "  InstructionOperand temps[] = {g.TempRegister(rax)};\n"
    "  Emit(kSSEFloat64Mod, g.DefineSameAsFirst(node), g.UseRegister(op.left()),\n"
    "       g.UseRegister(op.right()), 1, temps);\n",
    "  Emit(kSSEFloat64Mod, g.DefineAsFixed(node, xmm0), g.UseFixed(op.left(), xmm0),\n"
    "       g.UseFixed(op.right(), xmm1))\n"
    "      ->MarkAsCall();\n",
)

replace_block(
    "src/compiler/backend/x64/code-generator-x64.cc",
    "    case kSSEFloat64Mod: {\n",
    "    case kSSEFloat32Max: {\n",
    "    case kSSEFloat64Mod: {\n"
    "      __ PrepareCallCFunction(2);\n"
    "      __ CallCFunction(ExternalReference::mod_two_doubles_operation(), 2);\n"
    "      break;\n"
    "    }\n",
)

replace_once(
    "src/maglev/maglev-ir.h",
    "#if defined(V8_TARGET_ARCH_ARM64) || defined(V8_TARGET_ARCH_ARM) || \\\n"
    "    defined(V8_TARGET_ARCH_RISCV64) || defined(V8_TARGET_ARCH_LOONG64)\n"
    "// On Arm/Arm64/Riscv64/LoongArch64, floating point modulus",
    "#if defined(V8_TARGET_ARCH_X64) || \\\n"
    "    defined(V8_TARGET_ARCH_ARM64) || defined(V8_TARGET_ARCH_ARM) || \\\n"
    "    defined(V8_TARGET_ARCH_RISCV64) || defined(V8_TARGET_ARCH_LOONG64)\n"
    "// On Arm/Arm64/Riscv64/LoongArch64, floating point modulus",
)

replace_block(
    "src/maglev/x64/maglev-ir-x64.cc",
    "void Float64Modulus::SetValueLocationConstraints() {\n",
    "void Float64Negate::SetValueLocationConstraints() {\n",
    "int Float64Modulus::MaxCallStackArgs() const {\n"
    "  return MaglevAssembler::ArgumentStackSlotsForCFunctionCall(2);\n"
    "}\n"
    "void Float64Modulus::SetValueLocationConstraints() {\n"
    "  UseFixed(LeftInput(), xmm0);\n"
    "  UseFixed(RightInput(), xmm1);\n"
    "  DefineSameAsFirst(this);\n"
    "}\n"
    "void Float64Modulus::GenerateCode(MaglevAssembler* masm,\n"
    "                                  const ProcessingState& state) {\n"
    "  AllowExternalCallThatCantCauseGC scope(masm);\n"
    "  __ PrepareCallCFunction(2);\n"
    "  __ CallCFunction(ExternalReference::mod_two_doubles_operation(), 2);\n"
    "}\n"
    "\n",
)
