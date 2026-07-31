#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <stddef.h>

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef unsigned char GLubyte;

#define GL_VENDOR                   0x1F00
#define GL_RENDERER                 0x1F01
#define GL_VERSION                  0x1F02
#define GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define GL_EXTENSIONS               0x1F03
#define GL_NUM_EXTENSIONS           0x821D
#define GL_MAX_TEXTURE_SIZE         0x0D33
#define GL_MAX_RENDERBUFFER_SIZE    0x84E8
#define GL_MAX_VIEWPORT_DIMS        0x0D3A
#define GL_MAX_TEXTURE_IMAGE_UNITS  0x8872
#define GL_MAX_VERTEX_ATTRIBS       0x8869

/* EGL */
typedef void *EGLDisplay;
typedef int EGLint;
#define EGL_VENDOR      0x3053
#define EGL_VERSION_STR 0x3054
#define EGL_EXTENSIONS  0x3055
#define EGL_CLIENT_APIS 0x308D

static const char *fake_renderer(void) {
    const char *v = getenv("OBSIDIAN_GPU_RENDERER");
    return (v && *v) ? v : "Mesa Intel(R) HD Graphics 630 (Kaby Lake GT2)";
}

static const char *fake_vendor(void) {
    const char *v = getenv("OBSIDIAN_GPU_VENDOR");
    return (v && *v) ? v : "Intel";
}

/* The GL extension list is one of the highest-entropy fingerprints
 * available to a graphical application - it is effectively unique
 * per driver build. It is blanked by default.
 *
 * Some applications refuse to start without a specific extension.
 * If one does, set OBSIDIAN_GL_EXTENSIONS=preserve to pass the real
 * list through; you keep every other GPU protection and lose only
 * this one. */
static int preserve_extensions(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("OBSIDIAN_GL_EXTENSIONS");
        cached = (e && strcmp(e, "preserve") == 0) ? 1 : 0;
    }
    return cached;
}

const GLubyte *glGetString(GLenum name) {
    static const GLubyte *(*real_glGetString)(GLenum) = NULL;
    if (!real_glGetString) real_glGetString = dlsym(RTLD_NEXT, "glGetString");

    switch (name) {
        case GL_VENDOR:   return (const GLubyte *)fake_vendor();
        case GL_RENDERER: return (const GLubyte *)fake_renderer();
        case GL_VERSION:  return (const GLubyte *)"OpenGL ES 3.2 Mesa 21.0.0";
        case GL_SHADING_LANGUAGE_VERSION:
                          return (const GLubyte *)"OpenGL ES GLSL ES 3.20";
        case GL_EXTENSIONS:
            if (preserve_extensions() && real_glGetString)
                return real_glGetString(name);
            return (const GLubyte *)"";
        default:
            if (real_glGetString) return real_glGetString(name);
            return (const GLubyte *)"";
    }
}

const GLubyte *glGetStringi(GLenum name, GLuint index) {
    static const GLubyte *(*real_glGetStringi)(GLenum, GLuint) = NULL;
    if (!real_glGetStringi) real_glGetStringi = dlsym(RTLD_NEXT, "glGetStringi");
    if (preserve_extensions() && real_glGetStringi)
        return real_glGetStringi(name, index);
    (void)name; (void)index;
    return (const GLubyte *)"";
}

void glGetIntegerv(GLenum pname, GLint *data) {
    static void (*real_glGetIntegerv)(GLenum, GLint *) = NULL;
    if (!real_glGetIntegerv) real_glGetIntegerv = dlsym(RTLD_NEXT, "glGetIntegerv");
    if (!data) { if (real_glGetIntegerv) real_glGetIntegerv(pname, data); return; }

    switch (pname) {
        case GL_MAX_TEXTURE_SIZE:        *data = 16384; return;
        case GL_MAX_RENDERBUFFER_SIZE:   *data = 16384; return;
        case GL_MAX_VIEWPORT_DIMS:       data[0] = 16384; data[1] = 16384; return;
        case GL_MAX_TEXTURE_IMAGE_UNITS: *data = 16; return;
        case GL_MAX_VERTEX_ATTRIBS:      *data = 16; return;
        /* Keep the count consistent with the blanked extension list,
         * otherwise applications loop over glGetStringi() reading
         * empty strings and some abort. */
        case GL_NUM_EXTENSIONS:
            if (!preserve_extensions()) { *data = 0; return; }
            break;
        default: break;
    }
    if (real_glGetIntegerv) real_glGetIntegerv(pname, data);
}

/* EGL vendor string only. EGL_EXTENSIONS is deliberately passed
 * through: Wayland EGL clients require EGL_KHR_platform_wayland and
 * friends, and blanking that list breaks them outright. */
const char *eglQueryString(EGLDisplay dpy, EGLint name) {
    static const char *(*real_eglQueryString)(EGLDisplay, EGLint) = NULL;
    if (!real_eglQueryString) real_eglQueryString = dlsym(RTLD_NEXT, "eglQueryString");
    if (name == EGL_VENDOR) return fake_vendor();
    if (real_eglQueryString) return real_eglQueryString(dpy, name);
    return "";
}
