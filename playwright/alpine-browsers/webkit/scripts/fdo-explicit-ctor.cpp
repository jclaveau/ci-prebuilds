/*
 * Iter #9 patched fdo.cpp — replace static struct initializer (stateless
 * lambda → fn ptr) with __attribute__((constructor)) explicit init.
 *
 * Original problem: nm reports _wpe_loader_interface as `B` (BSS), and
 * WebKit's main process reads load_object as NULL despite standalone
 * dlopen populating it. The ctor approach guarantees the field is
 * populated at lib-load time on every load path.
 */
#include "interfaces.h"
#include <cstring>
#include <wpe/wpe.h>

extern "C" {

__attribute__((visibility("default")))
struct wpe_loader_interface _wpe_loader_interface;

static void* fdo_load_object(const char* object_name)
{
    if (!std::strcmp(object_name, "_wpe_renderer_host_interface"))
        return &fdo_renderer_host;
    if (!std::strcmp(object_name, "_wpe_renderer_backend_egl_interface"))
        return &fdo_renderer_backend_egl;
    if (!std::strcmp(object_name, "_wpe_renderer_backend_egl_target_interface"))
        return &fdo_renderer_backend_egl_target;
    if (!std::strcmp(object_name, "_wpe_renderer_backend_egl_offscreen_target_interface"))
        return &fdo_renderer_backend_egl_offscreen_target;
    return nullptr;
}

__attribute__((constructor))
static void init_wpe_loader_interface(void)
{
    _wpe_loader_interface.load_object = fdo_load_object;
}

}
