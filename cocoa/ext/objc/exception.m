/*
 * exception.m -- exceptions crossing the bridge, in both directions.
 *
 * This is the one file compiled as Objective-C, because catching an
 * Objective-C exception needs @try/@catch. Everything else stays plain C.
 *
 * Two separate problems live here:
 *
 *   1. Cocoa raising while we are inside ffi_call. The exception unwinds with
 *      the C++ mechanism straight through libffi's frame and, with nothing to
 *      catch it, reaches libc++abi and terminates the process. Wrapping the
 *      call lets us turn it into a Ruby exception instead.
 *
 *   2. A Ruby callback raising while Objective-C is on the stack. That must
 *      not unwind (Ruby uses longjmp, which would skip Objective-C cleanup),
 *      so closure.c and block.c trap it with rb_protect and park it here. It
 *      is then re-raised the moment control returns to Ruby.
 */
#include "rubyobjc.h"
#import <Foundation/Foundation.h>

VALUE rb_eObjCException = Qnil;

/* ---- Objective-C exceptions -> Ruby --------------------------------------- */

id
robjc_ffi_call_protected(ffi_cif *cif, void *fn, void *rvalue, void **avalues)
{
    @try {
        ffi_call(cif, FFI_FN(fn), rvalue, avalues);
    }
    @catch (NSException *e) {
        return (id)[e retain];
    }
    @catch (id e) {
        /* Objective-C permits throwing any object, not just NSException. */
        return (id)[e retain];
    }
    return nil;
}

static VALUE
nsstring_to_ruby(id str)
{
    if (str == nil) return Qnil;
    const char *utf8 = [(NSString *)str UTF8String];
    return utf8 == NULL ? Qnil : rb_utf8_str_new_cstr(utf8);
}

static bool
responds(id obj, const char *selector)
{
    return [obj respondsToSelector:sel_registerName(selector)];
}

/* Convert a caught Objective-C exception into a Ruby one and raise it. Takes
 * ownership of the +1 reference from robjc_ffi_call_protected. */
void
robjc_raise_objc_exception(id exc)
{
    VALUE name   = Qnil;
    VALUE reason = Qnil;

    if (responds(exc, "name"))   name   = nsstring_to_ruby([(NSException *)exc name]);
    if (responds(exc, "reason")) reason = nsstring_to_ruby([(NSException *)exc reason]);

    VALUE message;
    if (!NIL_P(name) && !NIL_P(reason)) {
        message = rb_sprintf("%"PRIsVALUE": %"PRIsVALUE, name, reason);
    } else if (!NIL_P(name)) {
        message = name;
    } else {
        message = rb_str_new_cstr(object_getClassName(exc));
    }

    VALUE error = rb_exc_new_str(rb_eObjCException, message);
    rb_ivar_set(error, rb_intern("@name"), name);
    rb_ivar_set(error, rb_intern("@reason"), reason);
    /* Hand the NSException itself to Ruby, consuming the retain we hold. */
    rb_ivar_set(error, rb_intern("@objc_exception"), robjc_wrap_object(exc, true));

    if (responds(exc, "userInfo")) {
        id info = [(NSException *)exc userInfo];
        rb_ivar_set(error, rb_intern("@user_info"),
                    info == nil ? Qnil : robjc_wrap_object(info, false));
    }

    rb_exc_raise(error);
}

/* ---- Ruby exceptions parked during an Objective-C callback ---------------- */

static VALUE pending = Qnil;

void
robjc_stash_ruby_exception(VALUE err)
{
    if (NIL_P(err)) return;

    if (!NIL_P(pending)) {
        /* Only one can be re-raised; report the loser rather than lose it. */
        VALUE msg = rb_funcall(err, rb_intern("message"), 0);
        fprintf(stderr, "[cocoa] dropped a second callback exception: %s\n",
                StringValueCStr(msg));
        return;
    }
    pending = err;
}

bool
robjc_has_pending(void)
{
    return !NIL_P(pending);
}

void
robjc_reraise_pending(void)
{
    if (NIL_P(pending)) return;
    VALUE err = pending;
    pending = Qnil;
    rb_exc_raise(err);
}

void
Init_exception(void)
{
    rb_gc_register_address(&pending);

    rb_eObjCException = rb_define_class_under(rb_mObjC, "Exception", rb_eObjCError);
    rb_define_attr(rb_eObjCException, "name", 1, 0);
    rb_define_attr(rb_eObjCException, "reason", 1, 0);
    rb_define_attr(rb_eObjCException, "objc_exception", 1, 0);
    rb_define_attr(rb_eObjCException, "user_info", 1, 0);
}
