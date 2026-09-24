/*
 * rubyobjc.h -- shared declarations for the Ruby <-> Objective-C bridge.
 *
 * The bridge has three layers:
 *   encoding.c  -- Objective-C type encodings  ->  libffi type descriptions
 *   invoke.c    -- libffi call machinery over objc_msgSend, plus value marshalling
 *   objc_ext.c  -- Ruby object model: wrappers, class proxies, module entry points
 */
#ifndef RUBYOBJC_H
#define RUBYOBJC_H

#include <ruby.h>
#include <ffi/ffi.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <stdbool.h>

/* libobjc's ARC entry points. Declared by hand so this file stays plain C
 * and does not need to be compiled as Objective-C. */
extern id    objc_retain(id);
extern void  objc_release(id);
extern void *objc_autoreleasePoolPush(void);
extern void  objc_autoreleasePoolPop(void *);

extern VALUE rb_mObjC;
extern VALUE rb_cObjCObject;
extern VALUE rb_cObjCClass;
extern VALUE rb_cObjCPointer;
extern VALUE rb_cObjCBlock;
extern VALUE rb_eObjCError;
extern VALUE rb_eObjCException;

/* ---- encoding.c ---------------------------------------------------------- */

/* A parsed method signature: everything needed to make one ffi_call. */
typedef struct {
    ffi_cif      cif;
    ffi_type    *rtype;
    ffi_type   **atypes;
    char        *ret_enc;    /* encoding of the return value          */
    char       **arg_enc;    /* encoding of each argument, incl self/_cmd */
    unsigned int nargs;      /* total arity, including self and _cmd   */
    bool         use_stret;  /* return via objc_msgSend_stret (x86_64) */
    bool         variadic;
} robjc_sig_t;

const char *robjc_skip_modifiers(const char *p);
const char *robjc_skip_type(const char *p);
ffi_type   *robjc_ffi_type_for(const char **pp);
ffi_type   *robjc_ffi_type_parse(const char *enc);

/* Parse (and memoize) a full Objective-C method type encoding such as
 * "@32@0:8@16". Returns NULL and sets *err on failure. */
robjc_sig_t *robjc_sig_for_method(const char *enc, const char **err);

/* Build (and memoize) a signature from separate return/arg encodings, for
 * plain C functions reached through dlsym. */
robjc_sig_t *robjc_sig_for_function(const char *ret_enc, const char **arg_encs,
                                    unsigned int nargs, const char **err);

/* ---- invoke.c ------------------------------------------------------------ */

void  robjc_ruby_to_c(const char *enc, ffi_type *t, VALUE v, void *slot);
VALUE robjc_c_to_ruby(const char *enc, ffi_type *t, void *slot);

id    robjc_value_to_id(VALUE v);
void  robjc_clear_struct_cache(void);
SEL   robjc_value_to_sel(VALUE v);

VALUE robjc_msgsend(id recv, SEL sel, int argc, VALUE *argv);
VALUE robjc_call_function(void *fn, robjc_sig_t *sig, int argc, VALUE *argv);

/* Generalised call: `fixed` slots are passed ahead of the Ruby arguments.
 * Methods supply self and _cmd; blocks supply the block pointer itself. */
VALUE robjc_invoke(void *fn, robjc_sig_t *sig, void **fixed, unsigned int nfixed,
                   int argc, VALUE *argv, SEL owner_sel);

/* ---- objc_ext.c ---------------------------------------------------------- */

/* Wrap an Objective-C instance. When `consume` is true the caller is handing
 * over a +1 reference (alloc/new/copy/mutableCopy) and the bridge does not
 * retain again. */
VALUE robjc_wrap_object(id obj, bool consume);
VALUE robjc_wrap_as(VALUE klass, id obj, bool consume);
VALUE robjc_wrap_class(Class cls);
VALUE robjc_wrap_pointer(void *ptr);
id    robjc_unwrap(VALUE v);
bool  robjc_is_wrapper(VALUE v);
bool  robjc_selector_consumes_self(const char *name);
void  robjc_disown(VALUE v);

/* ---- closure.c ----------------------------------------------------------- */

void  Init_closure(void);

/* ---- block.c ------------------------------------------------------------- */

void  Init_block(void);

/* ---- exception.m --------------------------------------------------------- */

/* Run one ffi_call with Objective-C exceptions trapped. Returns nil normally,
 * or the caught exception with a +1 reference the caller must consume. */
id    robjc_ffi_call_protected(ffi_cif *cif, void *fn, void *rvalue, void **avalues);

/* Raise a caught Objective-C exception as ObjC::Exception, consuming it. */
NORETURN(void robjc_raise_objc_exception(id exc));

/* Park a Ruby exception raised inside a callback, and re-raise it once
 * control is back in Ruby. */
void  robjc_stash_ruby_exception(VALUE err);
void  robjc_reraise_pending(void);
bool  robjc_has_pending(void);

void  Init_exception(void);

#endif /* RUBYOBJC_H */
