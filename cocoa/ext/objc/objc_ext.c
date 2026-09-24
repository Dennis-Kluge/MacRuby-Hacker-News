/*
 * objc_ext.c -- the Ruby-facing surface of the bridge.
 *
 * Objective-C instances are wrapped in TypedData objects that hold exactly one
 * strong reference each: acquired on wrap, released when Ruby's GC collects the
 * wrapper. Classes are wrapped without refcounting, since they are immortal.
 */
#include "rubyobjc.h"
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>

VALUE rb_mObjC       = Qnil;
VALUE rb_cObjCObject = Qnil;
VALUE rb_cObjCClass  = Qnil;
VALUE rb_cObjCPointer = Qnil;
VALUE rb_cObjCBlock  = Qnil;
VALUE rb_eObjCError  = Qnil;

typedef struct {
    id   obj;
    bool is_class;
} robjc_obj_t;

typedef struct {
    void *ptr;
} robjc_ptr_t;

/* ---- object wrapper ------------------------------------------------------ */

static void
obj_free(void *p)
{
    robjc_obj_t *w = (robjc_obj_t *)p;
    if (!w->is_class && w->obj != nil) {
        objc_release(w->obj);
    }
    xfree(w);
}

static size_t
obj_size(const void *p)
{
    (void)p;
    return sizeof(robjc_obj_t);
}

static const rb_data_type_t objc_obj_type = {
    "ObjC::Object",
    { NULL, obj_free, obj_size },
    NULL, NULL,
    RUBY_TYPED_FREE_IMMEDIATELY
};

static void
ptr_free(void *p)
{
    xfree(p);
}

static size_t
ptr_size(const void *p)
{
    (void)p;
    return sizeof(robjc_ptr_t);
}

static const rb_data_type_t objc_ptr_type = {
    "ObjC::Pointer",
    { NULL, ptr_free, ptr_size },
    NULL, NULL,
    RUBY_TYPED_FREE_IMMEDIATELY
};

bool
robjc_is_wrapper(VALUE v)
{
    return rb_typeddata_is_kind_of(v, &objc_obj_type) ||
           rb_typeddata_is_kind_of(v, &objc_ptr_type);
}

id
robjc_unwrap(VALUE v)
{
    if (NIL_P(v)) return nil;
    if (rb_typeddata_is_kind_of(v, &objc_obj_type)) {
        robjc_obj_t *w;
        TypedData_Get_Struct(v, robjc_obj_t, &objc_obj_type, w);
        return w->obj;
    }
    if (rb_typeddata_is_kind_of(v, &objc_ptr_type)) {
        robjc_ptr_t *w;
        TypedData_Get_Struct(v, robjc_ptr_t, &objc_ptr_type, w);
        return (id)w->ptr;
    }
    rb_raise(rb_eTypeError, "not an Objective-C object");
}

VALUE
robjc_wrap_as(VALUE klass, id obj, bool consume)
{
    if (obj == nil) return Qnil;

    robjc_obj_t *w;
    VALUE v = TypedData_Make_Struct(klass, robjc_obj_t, &objc_obj_type, w);
    /* Take exactly one strong reference. If the caller already owns a +1
     * (alloc/new/copy), adopt it rather than retaining a second time. */
    w->obj      = consume ? obj : objc_retain(obj);
    w->is_class = false;
    return v;
}

/* Every block flavour (__NSMallocBlock__, __NSGlobalBlock__, __NSStackBlock__)
 * is a direct subclass of NSBlock, so recognising one costs a single
 * superclass comparison. Worth it: a block returned through a plain "@" -- out
 * of an NSArray, say -- should still arrive as something callable. */
static bool
object_is_block(id obj)
{
    static Class ns_block = Nil;
    static bool  resolved = false;

    if (!resolved) {
        ns_block = objc_getClass("NSBlock");
        resolved = true;
    }
    if (ns_block == Nil) return false;

    Class cls = object_getClass(obj);
    return cls == ns_block || class_getSuperclass(cls) == ns_block;
}

VALUE
robjc_wrap_object(id obj, bool consume)
{
    if (obj != nil && object_is_block(obj)) {
        return robjc_wrap_as(rb_cObjCBlock, obj, consume);
    }
    return robjc_wrap_as(rb_cObjCObject, obj, consume);
}

VALUE
robjc_wrap_class(Class cls)
{
    if (cls == Nil) return Qnil;

    robjc_obj_t *w;
    VALUE v = TypedData_Make_Struct(rb_cObjCClass, robjc_obj_t,
                                    &objc_obj_type, w);
    w->obj      = (id)cls;
    w->is_class = true;
    return v;
}

VALUE
robjc_wrap_pointer(void *ptr)
{
    if (ptr == NULL) return Qnil;

    robjc_ptr_t *w;
    VALUE v = TypedData_Make_Struct(rb_cObjCPointer, robjc_ptr_t,
                                    &objc_ptr_type, w);
    w->ptr = ptr;
    return v;
}

/* ---- instance methods ---------------------------------------------------- */

/* Give up ownership without releasing: the reference has gone elsewhere. */
void
robjc_disown(VALUE v)
{
    if (!rb_typeddata_is_kind_of(v, &objc_obj_type)) return;

    robjc_obj_t *w;
    TypedData_Get_Struct(v, robjc_obj_t, &objc_obj_type, w);
    w->obj = nil;
}

static VALUE
rb_objc_send(int argc, VALUE *argv, VALUE self)
{
    if (argc < 1) {
        rb_raise(rb_eArgError, "objc_send requires a selector");
    }
    id  recv = robjc_unwrap(self);
    SEL sel  = robjc_value_to_sel(argv[0]);
    VALUE result = robjc_msgsend(recv, sel, argc - 1, argv + 1);

    /* An init consumes the receiver: it may return a different object, or nil
     * after releasing this one. Either way this wrapper no longer owns it. */
    if (robjc_selector_consumes_self(sel_getName(sel))) {
        robjc_disown(self);
    }
    return result;
}

static VALUE
rb_objc_responds_to(VALUE self, VALUE sel_name)
{
    id  recv = robjc_unwrap(self);
    if (recv == nil) return Qfalse;
    SEL sel  = robjc_value_to_sel(sel_name);
    return class_getInstanceMethod(object_getClass(recv), sel) != NULL
           ? Qtrue : Qfalse;
}

static VALUE
rb_objc_class_name(VALUE self)
{
    id recv = robjc_unwrap(self);
    if (recv == nil) return Qnil;
    return rb_str_new_cstr(class_getName(object_getClass(recv)));
}

static VALUE
rb_objc_get_class(VALUE self)
{
    id recv = robjc_unwrap(self);
    if (recv == nil) return Qnil;
    return robjc_wrap_class(object_getClass(recv));
}

/* Class names from the receiver's own class up to the root, so BridgeSupport
 * metadata declared on a superclass (NSArray) is found for a concrete
 * subclass instance (__NSArrayI). */
static VALUE
rb_objc_class_chain(VALUE self)
{
    id recv = robjc_unwrap(self);
    VALUE out = rb_ary_new();
    if (recv == nil) return out;

    Class c = object_getClass(recv);
    while (c != Nil) {
        rb_ary_push(out, rb_str_new_cstr(class_getName(c)));
        c = class_getSuperclass(c);
    }
    return out;
}

static VALUE
rb_objc_address(VALUE self)
{
    return ULL2NUM((unsigned long long)(uintptr_t)robjc_unwrap(self));
}

/* Bridge -[NSObject description] into a Ruby String. */
static VALUE
rb_objc_to_s(VALUE self)
{
    id recv = robjc_unwrap(self);
    if (recv == nil) return rb_str_new_cstr("nil");

    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id desc = send(recv, sel_registerName("description"));
    if (desc == nil) return rb_str_new_cstr("(no description)");

    const char *(*utf8)(id, SEL) = (const char *(*)(id, SEL))objc_msgSend;
    const char *s = utf8(desc, sel_registerName("UTF8String"));
    return s == NULL ? rb_str_new_cstr("(no description)") : rb_utf8_str_new_cstr(s);
}

static VALUE
rb_objc_equal(VALUE self, VALUE other)
{
    id a = robjc_unwrap(self);
    if (!robjc_is_wrapper(other)) return Qfalse;
    id b = robjc_unwrap(other);
    if (a == b) return Qtrue;
    if (a == nil || b == nil) return Qfalse;

    signed char (*send)(id, SEL, id) = (signed char (*)(id, SEL, id))objc_msgSend;
    return send(a, sel_registerName("isEqual:"), b) ? Qtrue : Qfalse;
}

static VALUE
rb_objc_class_get_name(VALUE self)
{
    id cls = robjc_unwrap(self);
    return cls == nil ? Qnil : rb_str_new_cstr(class_getName((Class)cls));
}

static VALUE
rb_objc_class_superclass_name(VALUE self)
{
    id cls = robjc_unwrap(self);
    if (cls == nil) return Qnil;
    Class super = class_getSuperclass((Class)cls);
    return super == Nil ? Qnil : rb_str_new_cstr(class_getName(super));
}

/* The raw type encoding of one method, for introspection. */
static VALUE
rb_objc_method_encoding(VALUE mod, VALUE cls_v, VALUE sel_name, VALUE class_method)
{
    (void)mod;
    Class cls = (Class)robjc_unwrap(cls_v);
    if (cls == Nil) return Qnil;
    if (RTEST(class_method)) cls = object_getClass((id)cls);

    Method m = class_getInstanceMethod(cls, robjc_value_to_sel(sel_name));
    if (m == NULL) return Qnil;

    const char *enc = method_getTypeEncoding(m);
    return enc == NULL ? Qnil : rb_str_new_cstr(enc);
}

static VALUE
rb_objc_ptr_address(VALUE self)
{
    robjc_ptr_t *w;
    TypedData_Get_Struct(self, robjc_ptr_t, &objc_ptr_type, w);
    return ULL2NUM((unsigned long long)(uintptr_t)w->ptr);
}

/* Out-parameters are common in Cocoa (the BOOL *stop of an enumeration block,
 * NSError **). These give Ruby the minimum needed to read and write them. */
static void *
ptr_of(VALUE self)
{
    robjc_ptr_t *w;
    TypedData_Get_Struct(self, robjc_ptr_t, &objc_ptr_type, w);
    if (w->ptr == NULL) rb_raise(rb_eObjCError, "null pointer");
    return w->ptr;
}

static VALUE rb_ptr_read_bool(VALUE self)   { return *(signed char *)ptr_of(self) ? Qtrue : Qfalse; }
static VALUE rb_ptr_read_int(VALUE self)    { return LL2NUM(*(long long *)ptr_of(self)); }
static VALUE rb_ptr_read_double(VALUE self) { return DBL2NUM(*(double *)ptr_of(self)); }

static VALUE
rb_ptr_read_object(VALUE self)
{
    id obj = *(id *)ptr_of(self);
    return obj == nil ? Qnil : robjc_wrap_object(obj, false);
}

static VALUE
rb_ptr_write_bool(VALUE self, VALUE v)
{
    *(signed char *)ptr_of(self) = RTEST(v) ? 1 : 0;
    return v;
}

static VALUE
rb_ptr_write_int(VALUE self, VALUE v)
{
    *(long long *)ptr_of(self) = NUM2LL(v);
    return v;
}

static VALUE
rb_ptr_write_double(VALUE self, VALUE v)
{
    *(double *)ptr_of(self) = NUM2DBL(v);
    return v;
}

/* ---- module functions ---------------------------------------------------- */

static VALUE
rb_objc_clear_struct_cache(VALUE mod)
{
    (void)mod;
    robjc_clear_struct_cache();
    return Qnil;
}

static VALUE
rb_objc_class_named(VALUE mod, VALUE name)
{
    (void)mod;
    Class cls = objc_getClass(StringValueCStr(name));
    return cls == Nil ? Qnil : robjc_wrap_class(cls);
}

static VALUE
rb_objc_load_framework(VALUE mod, VALUE path)
{
    (void)mod;
    void *h = dlopen(StringValueCStr(path), RTLD_LAZY | RTLD_GLOBAL);
    if (h == NULL) {
        rb_raise(rb_eObjCError, "could not load %s: %s",
                 StringValueCStr(path), dlerror());
    }
    return Qtrue;
}

/* Read the value of an exported C global, such as NSApplicationDidFinish...
 * Notification (an NSString *) or a numeric constant. */
static VALUE
rb_objc_symbol_value(VALUE mod, VALUE name, VALUE enc)
{
    (void)mod;
    const char *sym = StringValueCStr(name);
    void *addr = dlsym(RTLD_DEFAULT, sym);
    if (addr == NULL) return Qnil;

    const char *e = StringValueCStr(enc);
    ffi_type   *t = robjc_ffi_type_parse(e);
    return robjc_c_to_ruby(e, t, addr);
}

static VALUE
rb_objc_symbol_defined(VALUE mod, VALUE name)
{
    (void)mod;
    return dlsym(RTLD_DEFAULT, StringValueCStr(name)) != NULL ? Qtrue : Qfalse;
}

/* Call a plain C function found by name: ObjC.call_c("NSBeep", "v", []) */
static VALUE
rb_objc_call_c(int argc, VALUE *argv, VALUE mod)
{
    (void)mod;
    if (argc < 3) {
        rb_raise(rb_eArgError,
                 "call_c(name, return_encoding, arg_encodings, *args)");
    }

    const char *name = StringValueCStr(argv[0]);
    void *fn = dlsym(RTLD_DEFAULT, name);
    if (fn == NULL) {
        rb_raise(rb_eObjCError, "no such C function: %s", name);
    }

    VALUE encs = argv[2];
    Check_Type(encs, T_ARRAY);
    long n = RARRAY_LEN(encs);

    const char **arg_encs = alloca(sizeof(char *) * (n > 0 ? n : 1));
    for (long i = 0; i < n; i++) {
        /* Bind to a local first: StringValueCStr takes the address of its
         * argument, and the array element is const. The String stays alive
         * because the array still references it. */
        VALUE enc_s = RARRAY_AREF(encs, i);
        arg_encs[i] = StringValueCStr(enc_s);
    }

    const char *err = NULL;
    robjc_sig_t *sig = robjc_sig_for_function(StringValueCStr(argv[1]),
                                              arg_encs, (unsigned int)n, &err);
    if (sig == NULL) {
        rb_raise(rb_eObjCError, "cannot build a call for %s: %s",
                 name, err ? err : "unknown");
    }

    return robjc_call_function(fn, sig, argc - 3, argv + 3);
}

static VALUE
pool_ensure(VALUE pool)
{
    objc_autoreleasePoolPop((void *)(uintptr_t)NUM2ULL(pool));
    return Qnil;
}

static VALUE
pool_body(VALUE unused)
{
    (void)unused;
    return rb_yield(Qnil);
}

static VALUE
rb_objc_autorelease_pool(VALUE mod)
{
    (void)mod;
    void *pool = objc_autoreleasePoolPush();
    return rb_ensure(pool_body, Qnil, pool_ensure,
                     ULL2NUM((unsigned long long)(uintptr_t)pool));
}

/* Every registered Objective-C class name, for introspection and for building
 * the Ruby-side constant lookup. */
static VALUE
rb_objc_class_names(VALUE mod)
{
    (void)mod;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    VALUE  out = rb_ary_new_capa((long)count);
    for (unsigned int i = 0; i < count; i++) {
        rb_ary_push(out, rb_str_new_cstr(class_getName(classes[i])));
    }
    if (classes != NULL) free(classes);
    return out;
}

/* The selectors a class actually implements, used by respond_to? and docs. */
static VALUE
rb_objc_method_names(VALUE mod, VALUE cls_v, VALUE class_methods)
{
    (void)mod;
    Class cls = (Class)robjc_unwrap(cls_v);
    if (cls == Nil) return rb_ary_new();
    if (RTEST(class_methods)) cls = object_getClass((id)cls);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    VALUE   out = rb_ary_new_capa((long)count);
    for (unsigned int i = 0; i < count; i++) {
        rb_ary_push(out, rb_str_new_cstr(sel_getName(method_getName(methods[i]))));
    }
    if (methods != NULL) free(methods);
    return out;
}

void
Init_objc_ext(void)
{
    rb_mObjC = rb_define_module("ObjC");

    rb_eObjCError = rb_define_class_under(rb_mObjC, "Error", rb_eStandardError);

    rb_cObjCObject = rb_define_class_under(rb_mObjC, "Object", rb_cObject);
    rb_undef_alloc_func(rb_cObjCObject);
    rb_define_method(rb_cObjCObject, "objc_send",        rb_objc_send, -1);
    rb_define_method(rb_cObjCObject, "objc_responds_to?", rb_objc_responds_to, 1);
    rb_define_method(rb_cObjCObject, "objc_class_name",  rb_objc_class_name, 0);
    rb_define_method(rb_cObjCObject, "objc_class",       rb_objc_get_class, 0);
    rb_define_method(rb_cObjCObject, "objc_address",     rb_objc_address, 0);
    rb_define_method(rb_cObjCObject, "objc_class_chain", rb_objc_class_chain, 0);
    rb_define_method(rb_cObjCObject, "to_s",             rb_objc_to_s, 0);
    rb_define_method(rb_cObjCObject, "==",               rb_objc_equal, 1);

    rb_cObjCClass = rb_define_class_under(rb_mObjC, "Class", rb_cObjCObject);
    rb_undef_alloc_func(rb_cObjCClass);
    rb_define_method(rb_cObjCClass, "name", rb_objc_class_get_name, 0);
    rb_define_method(rb_cObjCClass, "superclass_name",
                     rb_objc_class_superclass_name, 0);

    rb_cObjCPointer = rb_define_class_under(rb_mObjC, "Pointer", rb_cObject);
    rb_undef_alloc_func(rb_cObjCPointer);
    rb_define_method(rb_cObjCPointer, "address",      rb_objc_ptr_address, 0);
    rb_define_method(rb_cObjCPointer, "read_bool",    rb_ptr_read_bool, 0);
    rb_define_method(rb_cObjCPointer, "read_int",     rb_ptr_read_int, 0);
    rb_define_method(rb_cObjCPointer, "read_double",  rb_ptr_read_double, 0);
    rb_define_method(rb_cObjCPointer, "read_object",  rb_ptr_read_object, 0);
    rb_define_method(rb_cObjCPointer, "write_bool",   rb_ptr_write_bool, 1);
    rb_define_method(rb_cObjCPointer, "write_int",    rb_ptr_write_int, 1);
    rb_define_method(rb_cObjCPointer, "write_double", rb_ptr_write_double, 1);

    rb_define_singleton_method(rb_mObjC, "class_named",     rb_objc_class_named, 1);
    rb_define_singleton_method(rb_mObjC, "clear_struct_cache",
                               rb_objc_clear_struct_cache, 0);
    rb_define_singleton_method(rb_mObjC, "load_framework",  rb_objc_load_framework, 1);
    rb_define_singleton_method(rb_mObjC, "symbol_value",    rb_objc_symbol_value, 2);
    rb_define_singleton_method(rb_mObjC, "symbol_defined?", rb_objc_symbol_defined, 1);
    rb_define_singleton_method(rb_mObjC, "call_c",          rb_objc_call_c, -1);
    rb_define_singleton_method(rb_mObjC, "autorelease_pool", rb_objc_autorelease_pool, 0);
    rb_define_singleton_method(rb_mObjC, "class_names",     rb_objc_class_names, 0);
    rb_define_singleton_method(rb_mObjC, "method_names",    rb_objc_method_names, 2);
    rb_define_singleton_method(rb_mObjC, "method_encoding",  rb_objc_method_encoding, 3);

    Init_exception();
    Init_closure();
    Init_block();
}
