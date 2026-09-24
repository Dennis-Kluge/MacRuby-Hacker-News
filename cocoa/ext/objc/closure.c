/*
 * closure.c -- implementing Objective-C methods in Ruby.
 *
 * Cocoa is callback-driven: targets/actions, delegates and data sources all
 * require handing the framework an object that implements selectors it will
 * call. libffi closures let us mint a real IMP at runtime whose body is a Ruby
 * block, which is what makes the bridge usable for actual applications rather
 * than one-way scripting.
 */
#include "rubyobjc.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    ffi_closure *closure;
    void        *code;
    robjc_sig_t *sig;
    VALUE        block;
} robjc_imp_t;

/* Blocks installed as method bodies must outlive the call that created them,
 * and the GC has no other reference to them. */
static VALUE imp_registry = Qnil;

typedef struct {
    robjc_imp_t *imp;
    void       **args;
    VALUE        result;
} imp_call_t;

static VALUE
imp_call_body(VALUE data)
{
    imp_call_t  *c   = (imp_call_t *)data;
    robjc_imp_t *imp = c->imp;
    robjc_sig_t *sig = imp->sig;

    /* args[0] is self and args[1] is _cmd; the block sees neither unless it
     * asks for them, so pass the receiver first and then the real arguments. */
    unsigned int n = sig->nargs > 2 ? sig->nargs - 2 : 0;
    VALUE *argv = ALLOCA_N(VALUE, n + 1);

    id self_obj = *(id *)c->args[0];
    argv[0] = self_obj == nil ? Qnil : robjc_wrap_object(self_obj, false);

    for (unsigned int i = 0; i < n; i++) {
        argv[i + 1] = robjc_c_to_ruby(sig->arg_enc[i + 2],
                                      sig->atypes[i + 2],
                                      c->args[i + 2]);
    }

    c->result = rb_funcallv(imp->block, rb_intern("call"), (int)(n + 1), argv);
    return Qnil;
}

/* The trampoline libffi jumps to. Runs on whatever thread Cocoa calls from. */
static void
imp_trampoline(ffi_cif *cif, void *ret, void **args, void *user)
{
    (void)cif;
    robjc_imp_t *imp = (robjc_imp_t *)user;
    robjc_sig_t *sig = imp->sig;

    imp_call_t call = { imp, args, Qnil };

    /* If an earlier callback already raised, run no further Ruby code until
     * that exception has surfaced. An enumeration that raised on its first
     * element would otherwise keep invoking the body for every remaining one. */
    if (robjc_has_pending()) {
        size_t skip = sig->rtype->size < sizeof(ffi_arg)
                    ? sizeof(ffi_arg) : sig->rtype->size;
        memset(ret, 0, skip);
        return;
    }

    /* A Ruby exception must not unwind through Objective-C frames, so trap it
     * here, report it, and return a zeroed value to the caller. */
    int state = 0;
    rb_protect(imp_call_body, (VALUE)&call, &state);

    size_t rsize = sig->rtype->size < sizeof(ffi_arg)
                 ? sizeof(ffi_arg) : sig->rtype->size;
    memset(ret, 0, rsize);

    if (state != 0) {
        /* Do not let this unwind into Objective-C frames: park it and
         * let robjc_invoke re-raise it when control reaches Ruby. */
        VALUE err = rb_errinfo();
        rb_set_errinfo(Qnil);
        robjc_stash_ruby_exception(err);
        return;
    }

    const char *renc = robjc_skip_modifiers(sig->ret_enc);
    if (*renc == 'v') return;

    if (*renc == '@' || *renc == '#') {
        *(id *)ret = robjc_value_to_id(call.result);
        return;
    }

    /* Integral returns narrower than a word must still occupy a full ffi_arg. */
    if (sig->rtype->size < sizeof(ffi_arg) &&
        sig->rtype->type != FFI_TYPE_FLOAT &&
        sig->rtype->type != FFI_TYPE_DOUBLE) {
        ffi_arg widened = 0;
        robjc_ruby_to_c(sig->ret_enc, sig->rtype, call.result, &widened);
        *(ffi_arg *)ret = widened;
        return;
    }

    robjc_ruby_to_c(sig->ret_enc, sig->rtype, call.result, ret);
}

/* ObjC.define_class("RubyDelegate", "NSObject") -> ObjC::Class */
static VALUE
rb_objc_define_class(VALUE mod, VALUE name, VALUE superclass)
{
    (void)mod;
    const char *cname = StringValueCStr(name);

    Class existing = objc_getClass(cname);
    if (existing != Nil) return robjc_wrap_class(existing);

    Class super = objc_getClass(StringValueCStr(superclass));
    if (super == Nil) {
        rb_raise(rb_eObjCError, "no such superclass: %s",
                 StringValueCStr(superclass));
    }

    Class cls = objc_allocateClassPair(super, cname, 0);
    if (cls == Nil) {
        rb_raise(rb_eObjCError, "could not allocate class %s", cname);
    }
    objc_registerClassPair(cls);
    return robjc_wrap_class(cls);
}

/*
 * ObjC.add_method(cls, "buttonClicked:", "v@:@") { |self, sender| ... }
 *
 * The type encoding follows the Objective-C convention: return type, then self
 * ('@') and _cmd (':'), then the declared arguments.
 */
static VALUE
rb_objc_add_method(VALUE mod, VALUE cls_v, VALUE sel_name, VALUE types)
{
    (void)mod;
    if (!rb_block_given_p()) {
        rb_raise(rb_eArgError, "add_method requires a block");
    }

    Class cls = (Class)robjc_unwrap(cls_v);
    if (cls == Nil) rb_raise(rb_eObjCError, "not a class");

    const char *enc = StringValueCStr(types);
    const char *err = NULL;
    robjc_sig_t *sig = robjc_sig_for_method(enc, &err);
    if (sig == NULL) {
        rb_raise(rb_eObjCError, "bad type encoding \"%s\": %s",
                 enc, err ? err : "unknown");
    }

    robjc_imp_t *imp = calloc(1, sizeof(robjc_imp_t));
    if (imp == NULL) rb_raise(rb_eNoMemError, "out of memory");

    imp->sig     = sig;
    imp->block   = rb_block_proc();
    imp->closure = ffi_closure_alloc(sizeof(ffi_closure), &imp->code);
    if (imp->closure == NULL) {
        free(imp);
        rb_raise(rb_eObjCError, "could not allocate an ffi closure");
    }

    if (ffi_prep_closure_loc(imp->closure, &sig->cif, imp_trampoline,
                             imp, imp->code) != FFI_OK) {
        ffi_closure_free(imp->closure);
        free(imp);
        rb_raise(rb_eObjCError, "ffi_prep_closure_loc failed");
    }

    /* Keep the block reachable for the life of the process. */
    rb_ary_push(imp_registry, imp->block);

    SEL sel = robjc_value_to_sel(sel_name);
    if (!class_addMethod(cls, sel, (IMP)imp->code, enc)) {
        /* Already present: replace it so redefinition works during development. */
        class_replaceMethod(cls, sel, (IMP)imp->code, enc);
    }

    return Qtrue;
}

/*
 * ObjC.add_protocol(cls, "NSTableViewDataSource")
 *
 * AppKit mostly checks respondsToSelector:, but some APIs test formal
 * conformance, and declaring it also makes the class introspect correctly.
 */
static VALUE
rb_objc_add_protocol(VALUE mod, VALUE cls_v, VALUE name)
{
    (void)mod;
    Class cls = (Class)robjc_unwrap(cls_v);
    if (cls == Nil) rb_raise(rb_eObjCError, "not a class");

    const char *pname = StringValueCStr(name);
    Protocol *proto = objc_getProtocol(pname);
    if (proto == NULL) {
        rb_raise(rb_eObjCError, "no such protocol: %s", pname);
    }

    return class_addProtocol(cls, proto) ? Qtrue : Qfalse;
}

static VALUE
rb_objc_conforms(VALUE mod, VALUE cls_v, VALUE name)
{
    (void)mod;
    Class cls = (Class)robjc_unwrap(cls_v);
    Protocol *proto = objc_getProtocol(StringValueCStr(name));
    if (cls == Nil || proto == NULL) return Qfalse;
    return class_conformsToProtocol(cls, proto) ? Qtrue : Qfalse;
}

void
Init_closure(void)
{
    imp_registry = rb_ary_new();
    rb_gc_register_address(&imp_registry);

    rb_define_singleton_method(rb_mObjC, "define_class", rb_objc_define_class, 2);
    rb_define_singleton_method(rb_mObjC, "add_method",   rb_objc_add_method, 3);
    rb_define_singleton_method(rb_mObjC, "add_protocol", rb_objc_add_protocol, 2);
    rb_define_singleton_method(rb_mObjC, "conforms?",    rb_objc_conforms, 2);
}
