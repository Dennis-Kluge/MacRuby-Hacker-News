/*
 * invoke.c -- marshalling between Ruby values and C, and the objc_msgSend call.
 */
#include "rubyobjc.h"
#include <string.h>
#include <stdlib.h>

/* ---- helpers ------------------------------------------------------------- */

static id
nsstring_from_ruby(VALUE v)
{
    static Class cls = NULL;
    static SEL   sel = NULL;
    if (cls == NULL) {
        cls = objc_getClass("NSString");
        sel = sel_registerName("stringWithUTF8String:");
    }
    id (*send)(Class, SEL, const char *) =
        (id (*)(Class, SEL, const char *))objc_msgSend;
    return send(cls, sel, StringValueCStr(v));
}

static id
nsnumber_from_ruby(VALUE v)
{
    static Class cls = NULL;
    if (cls == NULL) cls = objc_getClass("NSNumber");

    if (RB_FLOAT_TYPE_P(v)) {
        id (*send)(Class, SEL, double) = (id (*)(Class, SEL, double))objc_msgSend;
        return send(cls, sel_registerName("numberWithDouble:"), NUM2DBL(v));
    }
    if (v == Qtrue || v == Qfalse) {
        id (*send)(Class, SEL, signed char) =
            (id (*)(Class, SEL, signed char))objc_msgSend;
        return send(cls, sel_registerName("numberWithBool:"), v == Qtrue ? 1 : 0);
    }
    id (*send)(Class, SEL, long long) =
        (id (*)(Class, SEL, long long))objc_msgSend;
    return send(cls, sel_registerName("numberWithLongLong:"), NUM2LL(v));
}

id
robjc_value_to_id(VALUE v)
{
    if (NIL_P(v)) return nil;
    if (robjc_is_wrapper(v)) return robjc_unwrap(v);

    switch (TYPE(v)) {
      case T_STRING:
        return nsstring_from_ruby(v);
      case T_SYMBOL:
        return nsstring_from_ruby(rb_sym2str(v));
      case T_FIXNUM:
      case T_BIGNUM:
      case T_FLOAT:
      case T_TRUE:
      case T_FALSE:
        return nsnumber_from_ruby(v);
      case T_ARRAY: {
        static Class cls = NULL;
        if (cls == NULL) cls = objc_getClass("NSMutableArray");
        id (*new_send)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
        id arr = new_send(cls, sel_registerName("array"));
        void (*add)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        SEL add_sel = sel_registerName("addObject:");
        for (long i = 0; i < RARRAY_LEN(v); i++) {
            id elem = robjc_value_to_id(rb_ary_entry(v, i));
            if (elem != nil) add(arr, add_sel, elem);
        }
        return arr;
      }
      case T_HASH: {
        static Class cls = NULL;
        if (cls == NULL) cls = objc_getClass("NSMutableDictionary");
        id (*new_send)(Class, SEL) = (id (*)(Class, SEL))objc_msgSend;
        id dict = new_send(cls, sel_registerName("dictionary"));
        void (*setobj)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
        SEL set_sel = sel_registerName("setObject:forKey:");
        VALUE keys = rb_funcall(v, rb_intern("keys"), 0);
        for (long i = 0; i < RARRAY_LEN(keys); i++) {
            VALUE k = rb_ary_entry(keys, i);
            id ik = robjc_value_to_id(k);
            id iv = robjc_value_to_id(rb_hash_aref(v, k));
            if (ik != nil && iv != nil) setobj(dict, set_sel, iv, ik);
        }
        return dict;
      }
      default:
        rb_raise(rb_eTypeError,
                 "cannot convert %"PRIsVALUE" to an Objective-C object",
                 rb_obj_class(v));
    }
}

SEL
robjc_value_to_sel(VALUE v)
{
    if (NIL_P(v)) return NULL;
    if (SYMBOL_P(v)) return sel_registerName(RSTRING_PTR(rb_sym2str(v)));
    return sel_registerName(StringValueCStr(v));
}

static void *
value_to_pointer(VALUE v)
{
    if (NIL_P(v)) return NULL;
    if (robjc_is_wrapper(v)) return (void *)robjc_unwrap(v);
    if (RB_TYPE_P(v, T_STRING)) return (void *)RSTRING_PTR(v);
    if (RB_INTEGER_TYPE_P(v)) return (void *)(intptr_t)NUM2LL(v);
    rb_raise(rb_eTypeError, "cannot convert %"PRIsVALUE" to a pointer",
             rb_obj_class(v));
}

/* ---- struct marshalling -------------------------------------------------- */

static void set_scalar(ffi_type *t, VALUE v, void *slot);
static VALUE get_scalar(ffi_type *t, void *slot);

/* Structs are exchanged with Ruby as flat arrays of numbers: an NSRect is
 * [x, y, w, h] in either direction. Input is flattened first, so both
 * [0, 0, 480, 320] and [[0, 0], [480, 320]] are accepted. */
static void
fill_struct(ffi_type *t, VALUE flat, long *idx, void *base)
{
    size_t *offsets = alloca(sizeof(size_t) * 64);
    size_t  n = 0;
    while (t->elements[n] != NULL) n++;
    if (n > 64) rb_raise(rb_eArgError, "struct has too many fields");
    ffi_get_struct_offsets(FFI_DEFAULT_ABI, t, offsets);

    for (size_t i = 0; i < n; i++) {
        ffi_type *e = t->elements[i];
        void     *p = (char *)base + offsets[i];
        if (e->type == FFI_TYPE_STRUCT) {
            fill_struct(e, flat, idx, p);
        } else {
            VALUE v = (*idx < RARRAY_LEN(flat)) ? rb_ary_entry(flat, *idx) : INT2FIX(0);
            (*idx)++;
            set_scalar(e, v, p);
        }
    }
}

static void
read_struct(ffi_type *t, void *base, VALUE out)
{
    size_t *offsets = alloca(sizeof(size_t) * 64);
    size_t  n = 0;
    while (t->elements[n] != NULL) n++;
    if (n > 64) rb_raise(rb_eArgError, "struct has too many fields");
    ffi_get_struct_offsets(FFI_DEFAULT_ABI, t, offsets);

    for (size_t i = 0; i < n; i++) {
        ffi_type *e = t->elements[i];
        void     *p = (char *)base + offsets[i];
        if (e->type == FFI_TYPE_STRUCT) {
            read_struct(e, p, out);
        } else {
            rb_ary_push(out, get_scalar(e, p));
        }
    }
}

static void
set_scalar(ffi_type *t, VALUE v, void *slot)
{
    switch (t->type) {
      case FFI_TYPE_FLOAT:      *(float *)slot       = (float)NUM2DBL(v); break;
      case FFI_TYPE_DOUBLE:     *(double *)slot      = NUM2DBL(v);        break;
/* arm64 has no distinct long double: FFI_TYPE_LONGDOUBLE aliases
 * FFI_TYPE_DOUBLE there, so this case would be a duplicate. */
#if FFI_TYPE_LONGDOUBLE != FFI_TYPE_DOUBLE
      case FFI_TYPE_LONGDOUBLE: *(long double *)slot = (long double)NUM2DBL(v); break;
#endif
      case FFI_TYPE_SINT8:      *(int8_t *)slot      = (int8_t)(v == Qtrue ? 1 : v == Qfalse ? 0 : NUM2INT(v)); break;
      case FFI_TYPE_UINT8:      *(uint8_t *)slot     = (uint8_t)(v == Qtrue ? 1 : v == Qfalse ? 0 : NUM2UINT(v)); break;
      case FFI_TYPE_SINT16:     *(int16_t *)slot     = (int16_t)NUM2INT(v);  break;
      case FFI_TYPE_UINT16:     *(uint16_t *)slot    = (uint16_t)NUM2UINT(v); break;
      case FFI_TYPE_SINT32:     *(int32_t *)slot     = (int32_t)NUM2INT(v);  break;
      case FFI_TYPE_UINT32:     *(uint32_t *)slot    = (uint32_t)NUM2UINT(v); break;
      case FFI_TYPE_SINT64:     *(int64_t *)slot     = (int64_t)NUM2LL(v);   break;
      case FFI_TYPE_UINT64:     *(uint64_t *)slot    = (uint64_t)NUM2ULL(v); break;
      case FFI_TYPE_POINTER:    *(void **)slot       = value_to_pointer(v);  break;
      default:
        rb_raise(rb_eTypeError, "unsupported scalar field type %d", t->type);
    }
}

static VALUE
get_scalar(ffi_type *t, void *slot)
{
    switch (t->type) {
      case FFI_TYPE_FLOAT:      return DBL2NUM(*(float *)slot);
      case FFI_TYPE_DOUBLE:     return DBL2NUM(*(double *)slot);
#if FFI_TYPE_LONGDOUBLE != FFI_TYPE_DOUBLE
      case FFI_TYPE_LONGDOUBLE: return DBL2NUM((double)*(long double *)slot);
#endif
      case FFI_TYPE_SINT8:      return INT2NUM(*(int8_t *)slot);
      case FFI_TYPE_UINT8:      return UINT2NUM(*(uint8_t *)slot);
      case FFI_TYPE_SINT16:     return INT2NUM(*(int16_t *)slot);
      case FFI_TYPE_UINT16:     return UINT2NUM(*(uint16_t *)slot);
      case FFI_TYPE_SINT32:     return INT2NUM(*(int32_t *)slot);
      case FFI_TYPE_UINT32:     return UINT2NUM(*(uint32_t *)slot);
      case FFI_TYPE_SINT64:     return LL2NUM(*(int64_t *)slot);
      case FFI_TYPE_UINT64:     return ULL2NUM(*(uint64_t *)slot);
      case FFI_TYPE_POINTER: {
        void *p = *(void **)slot;
        return p == NULL ? Qnil : robjc_wrap_pointer(p);
      }
      default:
        rb_raise(rb_eTypeError, "unsupported scalar return type %d", t->type);
    }
}

/* ---- struct classes ------------------------------------------------------- */

/* Encoding tag -> Ruby class (or Qfalse when the tag has no class). Resolved
 * once per tag through Ruby, then answered from here. */
static VALUE struct_cache = Qnil;

void
robjc_clear_struct_cache(void)
{
    if (!NIL_P(struct_cache)) rb_hash_clear(struct_cache);
}

/* Look up the Array subclass that gives a struct's fields names, if Apple's
 * metadata described them. Returns Qnil when the struct is anonymous or
 * undescribed, in which case a plain Array is used. */
static VALUE
struct_class_for(const char *enc)
{
    if (*enc != '{') return Qnil;

    const char *start = enc + 1;
    const char *p     = start;
    while (*p != '\0' && *p != '=' && *p != '}') p++;
    if (p == start) return Qnil;

    VALUE tag = rb_str_new(start, (long)(p - start));

    if (NIL_P(struct_cache)) {
        struct_cache = rb_hash_new();
        rb_gc_register_address(&struct_cache);
    }

    VALUE hit = rb_hash_lookup2(struct_cache, tag, Qundef);
    if (hit != Qundef) {
        return hit == Qfalse ? Qnil : hit;
    }

    VALUE klass = rb_funcall(rb_mObjC, rb_intern("resolve_struct_class"), 1, tag);
    rb_hash_aset(struct_cache, rb_str_new_frozen(tag),
                 NIL_P(klass) ? Qfalse : klass);
    return klass;
}

/* ---- generic value conversion -------------------------------------------- */

void
robjc_ruby_to_c(const char *enc, ffi_type *t, VALUE v, void *slot)
{
    const char *e = robjc_skip_modifiers(enc);

    switch (*e) {
      case '@': *(id *)slot     = robjc_value_to_id(v);        return;
      case '#': *(Class *)slot  = (Class)robjc_value_to_id(v); return;
      case ':': *(SEL *)slot    = robjc_value_to_sel(v);       return;
      case '*': *(char **)slot  = NIL_P(v) ? NULL : StringValueCStr(v); return;
      case '^':
      case '?': *(void **)slot  = value_to_pointer(v);         return;
      case 'B': *(uint8_t *)slot = RTEST(v) ? 1 : 0;           return;
      case 'c': *(int8_t *)slot  = (int8_t)(v == Qtrue ? 1 : v == Qfalse ? 0 : NUM2INT(v)); return;
      case '{':
      case '(':
      case '[': {
        VALUE flat = rb_funcall(rb_Array(v), rb_intern("flatten"), 0);
        long  idx  = 0;
        memset(slot, 0, t->size);
        fill_struct(t, flat, &idx, slot);
        return;
      }
      default:
        set_scalar(t, v, slot);
        return;
    }
}

VALUE
robjc_c_to_ruby(const char *enc, ffi_type *t, void *slot)
{
    const char *e = robjc_skip_modifiers(enc);

    switch (*e) {
      case 'v': return Qnil;
      case '@': {
        id obj = *(id *)slot;
        if (obj == nil) return Qnil;
        /* "@?" is a block, which is an object with a callable body. */
        if (e[1] == '?') return robjc_wrap_as(rb_cObjCBlock, obj, false);
        return robjc_wrap_object(obj, false);
      }
      case '#': {
        Class c = *(Class *)slot;
        return c == Nil ? Qnil : robjc_wrap_class(c);
      }
      case ':': {
        SEL s = *(SEL *)slot;
        return s == NULL ? Qnil : rb_str_new_cstr(sel_getName(s));
      }
      case '*': {
        char *s = *(char **)slot;
        return s == NULL ? Qnil : rb_utf8_str_new_cstr(s);
      }
      case 'B': return *(uint8_t *)slot ? Qtrue : Qfalse;
      case 'c': {
        /* BOOL is `signed char` on x86_64, so a 'c' return is ambiguous.
         * Cocoa methods that return a genuine char are vanishingly rare, so
         * treat a clean 0/1 as a boolean and anything else as a number. */
        int8_t val = *(int8_t *)slot;
        if (val == 0) return Qfalse;
        if (val == 1) return Qtrue;
        return INT2NUM(val);
      }
      case '{':
      case '(':
      case '[': {
        VALUE out = rb_ary_new();
        read_struct(t, slot, out);

        VALUE klass = struct_class_for(e);
        if (!NIL_P(klass) && (long)RARRAY_LEN(out) ==
                             NUM2LONG(rb_funcall(klass, rb_intern("field_count"), 0))) {
            return rb_apply(klass, rb_intern("[]"), out);
        }
        return out;
      }
      default:
        return get_scalar(t, slot);
    }
}

/* ---- the call itself ----------------------------------------------------- */

/* Cocoa's ownership convention: these selector families return a +1 reference
 * that the caller owns. Everything else returns something autoreleased.
 *
 * "init" belongs here for a subtler reason: it *consumes* the receiver's +1
 * and hands back an owned object, which may be a different object or nil. The
 * receiver's wrapper has to give up ownership at the same time -- see
 * robjc_selector_consumes_self. */
static bool
selector_returns_retained(const char *name)
{
    static const char *families[] = { "alloc", "new", "copy", "mutableCopy",
                                      "init", NULL };
    for (int i = 0; families[i] != NULL; i++) {
        size_t len = strlen(families[i]);
        if (strncmp(name, families[i], len) == 0) {
            /* Must be the whole prefix, not e.g. "newsstandFoo". */
            char next = name[len];
            if (next == '\0' || next == ':' || (next >= 'A' && next <= 'Z')) {
                return true;
            }
        }
    }
    return false;
}

VALUE
robjc_invoke(void *fn, robjc_sig_t *sig, void **fixed, unsigned int nfixed,
             int argc, VALUE *argv, SEL owner_sel)
{
    if ((unsigned int)argc + nfixed != sig->nargs) {
        rb_raise(rb_eArgError, "wrong number of arguments (given %d, expected %u)",
                 argc, sig->nargs - nfixed);
    }

    void **avalues = alloca(sizeof(void *) * (sig->nargs > 0 ? sig->nargs : 1));

    for (unsigned int f = 0; f < nfixed; f++) {
        avalues[f] = fixed[f];
    }

    for (int i = 0; i < argc; i++) {
        unsigned int ai = (unsigned int)i + nfixed;
        ffi_type *t = sig->atypes[ai];
        size_t    sz = t->size < sizeof(long) ? sizeof(long) : t->size;
        void     *slot = alloca(sz);
        memset(slot, 0, sz);
        robjc_ruby_to_c(sig->arg_enc[ai], t, argv[i], slot);
        avalues[ai] = slot;
    }

    size_t rsize = sig->rtype->size < sizeof(long) ? sizeof(long) : sig->rtype->size;
    void  *rvalue = alloca(rsize);
    memset(rvalue, 0, rsize);

    id thrown = robjc_ffi_call_protected(&sig->cif, fn, rvalue, avalues);

    if (thrown != nil) {
        /* If one of our own callbacks raised first, that Ruby exception is the
         * root cause and the Objective-C one is downstream fallout. */
        if (robjc_has_pending()) {
            objc_release(thrown);
            robjc_reraise_pending();
        }
        robjc_raise_objc_exception(thrown);   /* does not return */
    }

    /* A Ruby callback may have raised while Objective-C was on the stack. */
    robjc_reraise_pending();

    /* Object returns need the ownership rule applied before wrapping. */
    const char *renc = robjc_skip_modifiers(sig->ret_enc);
    if (owner_sel != NULL && renc[0] == '@' && renc[1] != '?') {
        id result = *(id *)rvalue;
        if (result == nil) return Qnil;
        return robjc_wrap_object(result,
                                 selector_returns_retained(sel_getName(owner_sel)));
    }

    return robjc_c_to_ruby(sig->ret_enc, sig->rtype, rvalue);
}

/* Whether this selector takes over the receiver's reference. An init that
 * fails releases the object it was given and returns nil, so a wrapper that
 * kept on owning it would release freed memory. */
bool
robjc_selector_consumes_self(const char *name)
{
    if (strncmp(name, "init", 4) != 0) return false;

    char next = name[4];
    return next == '\0' || next == ':' || (next >= 'A' && next <= 'Z');
}

VALUE
robjc_msgsend(id recv, SEL sel, int argc, VALUE *argv)
{
    if (recv == nil) return Qnil;

    /* For a Class receiver object_getClass() yields the metaclass, so this one
     * lookup covers both instance methods and class methods. */
    Method m = class_getInstanceMethod(object_getClass(recv), sel);
    if (m == NULL) {
        rb_raise(rb_eNoMethodError, "%s does not respond to '%s'",
                 class_getName(object_getClass(recv)), sel_getName(sel));
    }

    const char *enc = method_getTypeEncoding(m);
    const char *err = NULL;
    robjc_sig_t *sig = robjc_sig_for_method(enc, &err);
    if (sig == NULL) {
        rb_raise(rb_eObjCError, "cannot build a call for '%s' (encoding \"%s\"): %s",
                 sel_getName(sel), enc ? enc : "(null)", err ? err : "unknown");
    }

    void *fn = (void *)objc_msgSend;
#if defined(__x86_64__)
    if (sig->use_stret) {
        fn = (void *)objc_msgSend_stret;
    }
#endif

    id  *recv_slot = alloca(sizeof(id));
    SEL *sel_slot  = alloca(sizeof(SEL));
    *recv_slot = recv;
    *sel_slot  = sel;
    void *fixed[2] = { recv_slot, sel_slot };

    return robjc_invoke(fn, sig, fixed, 2, argc, argv, sel);
}

VALUE
robjc_call_function(void *fn, robjc_sig_t *sig, int argc, VALUE *argv)
{
    return robjc_invoke(fn, sig, NULL, 0, argc, argv, NULL);
}
