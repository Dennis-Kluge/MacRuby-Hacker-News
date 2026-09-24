/*
 * block.c -- Objective-C blocks, in both directions.
 *
 * A block is an object whose first fields are a fixed C layout: an isa
 * pointer, flags, a function pointer, and a descriptor. Creating one from Ruby
 * means minting an invoke function with libffi (as closure.c does for methods)
 * and wrapping it in that layout. Reading one means walking the same layout to
 * recover the signature the compiler recorded, which lets a block received
 * from Cocoa be called from Ruby with no metadata at all.
 */
#include "rubyobjc.h"
#include <stdlib.h>
#include <string.h>

/* Blocks made here are heap blocks that the Objective-C runtime reference
 * counts like any other object: Cocoa retaining a completion handler keeps it
 * alive after Ruby has forgotten it, and the last release runs our dispose
 * helper. That is what lets them be freed at all -- a global block never is. */
extern void *_NSConcreteMallocBlock[32];

#define BLOCK_DEALLOCATING     (0x0001)
#define BLOCK_REFCOUNT_MASK    (0xfffe)
#define BLOCK_NEEDS_FREE       (1 << 24)
#define BLOCK_HAS_COPY_DISPOSE (1 << 25)
#define BLOCK_IS_GLOBAL        (1 << 28)
#define BLOCK_HAS_SIGNATURE    (1 << 30)

/* One reference, in the runtime's encoding: the count lives in bits 1-15. */
#define BLOCK_ONE_REFERENCE    (2)

struct block_descriptor {
    unsigned long  reserved;
    unsigned long  size;
    void         (*copy)(void *dst, const void *src);
    void         (*dispose)(const void *src);
    const char    *signature;
};

typedef struct block_impl block_impl_t;

struct block_layout {
    void                    *isa;
    int                      flags;
    int                      reserved;
    void                    *invoke;
    struct block_descriptor *descriptor;
    block_impl_t            *impl;      /* captured by the block */
};

struct block_impl {
    robjc_sig_t             *sig;
    VALUE                    proc;
    ffi_closure             *closure;
    struct block_descriptor *descriptor;
    /* Set from dispose, which may run on any thread, so it must not touch
     * Ruby. The sweep below does that later, on a Ruby thread. */
    volatile int             dead;
    struct block_impl       *next;
};

static block_impl_t *block_impls = NULL;
static unsigned long blocks_live = 0;
static unsigned long blocks_reaped = 0;

/* Release the resources of blocks the runtime has finished with. Runs on a
 * Ruby thread, where unregistering a GC root is safe. */
static void
reap_dead_blocks(void)
{
    block_impl_t **link = &block_impls;

    while (*link != NULL) {
        block_impl_t *impl = *link;
        if (!impl->dead) {
            link = &impl->next;
            continue;
        }

        *link = impl->next;

        rb_gc_unregister_address(&impl->proc);
        if (impl->closure != NULL) ffi_closure_free(impl->closure);
        if (impl->descriptor != NULL) {
            free((void *)impl->descriptor->signature);
            free(impl->descriptor);
        }
        free(impl);

        blocks_live--;
        blocks_reaped++;
    }
}

/* Called by the runtime when the last reference goes away, immediately before
 * the block's own memory is freed. */
static void
block_dispose_helper(const void *block)
{
    struct block_layout *blk = (struct block_layout *)block;
    if (blk != NULL && blk->impl != NULL) blk->impl->dead = 1;
}

/* Only reached if a stack block were copied, which cannot happen here, but the
 * runtime requires the pair when BLOCK_HAS_COPY_DISPOSE is set. */
static void
block_copy_helper(void *dst, const void *src)
{
    ((struct block_layout *)dst)->impl = ((struct block_layout *)src)->impl;
}

/* ---- Ruby block -> Objective-C block ------------------------------------- */

typedef struct {
    block_impl_t *impl;
    void        **args;
    VALUE         result;
} block_call_t;

static VALUE
block_call_body(VALUE data)
{
    block_call_t *c    = (block_call_t *)data;
    robjc_sig_t  *sig  = c->impl->sig;

    /* args[0] is the block itself; the Ruby proc never sees it. */
    unsigned int n = sig->nargs > 1 ? sig->nargs - 1 : 0;
    VALUE *argv = n > 0 ? ALLOCA_N(VALUE, n) : NULL;

    for (unsigned int i = 0; i < n; i++) {
        argv[i] = robjc_c_to_ruby(sig->arg_enc[i + 1],
                                  sig->atypes[i + 1],
                                  c->args[i + 1]);
    }

    c->result = rb_funcallv(c->impl->proc, rb_intern("call"), (int)n, argv);
    return Qnil;
}

static void
block_trampoline(ffi_cif *cif, void *ret, void **args, void *user)
{
    (void)cif;
    block_impl_t *impl = (block_impl_t *)user;
    robjc_sig_t  *sig  = impl->sig;

    block_call_t call = { impl, args, Qnil };

    /* If an earlier callback already raised, run no further Ruby code until
     * that exception has surfaced. An enumeration that raised on its first
     * element would otherwise keep invoking the body for every remaining one. */
    if (robjc_has_pending()) {
        size_t skip = sig->rtype->size < sizeof(ffi_arg)
                    ? sizeof(ffi_arg) : sig->rtype->size;
        memset(ret, 0, skip);
        return;
    }

    int state = 0;
    rb_protect(block_call_body, (VALUE)&call, &state);

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

/*
 * Build the method-style signature string the runtime expects in a block
 * descriptor, e.g. "v32@?0@8Q16^B24": return type, total frame size, then each
 * argument followed by its offset.
 */
static char *
build_signature(robjc_sig_t *sig)
{
    size_t *offsets = ALLOCA_N(size_t, sig->nargs > 0 ? sig->nargs : 1);
    size_t  total   = 0;

    for (unsigned int i = 0; i < sig->nargs; i++) {
        offsets[i] = total;
        size_t sz = sig->atypes[i]->size;
        if (sz < sizeof(void *)) sz = sizeof(void *);
        sz = (sz + sizeof(void *) - 1) & ~(sizeof(void *) - 1);
        total += sz;
    }

    VALUE str = rb_str_new_cstr("");
    rb_str_catf(str, "%s%lu", sig->ret_enc, (unsigned long)total);
    for (unsigned int i = 0; i < sig->nargs; i++) {
        rb_str_catf(str, "%s%lu", sig->arg_enc[i], (unsigned long)offsets[i]);
    }

    return strdup(StringValueCStr(str));
}

/*
 * ObjC.make_block("v", ["@", "Q", "^B"]) { |obj, idx, stop| ... }
 *
 * The encodings describe the block's own parameters; the leading block pointer
 * is added here.
 */
static VALUE
rb_objc_make_block(VALUE mod, VALUE ret_enc, VALUE arg_encs)
{
    (void)mod;
    if (!rb_block_given_p()) {
        rb_raise(rb_eArgError, "make_block requires a block");
    }
    Check_Type(arg_encs, T_ARRAY);

    long n = RARRAY_LEN(arg_encs);
    unsigned int total = (unsigned int)n + 1;

    const char **encs = ALLOCA_N(const char *, total);
    encs[0] = "@?";                       /* the block itself */
    for (long i = 0; i < n; i++) {
        VALUE e = RARRAY_AREF(arg_encs, i);
        encs[i + 1] = StringValueCStr(e);
    }

    const char *err = NULL;
    robjc_sig_t *sig = robjc_sig_for_function(StringValueCStr(ret_enc),
                                              encs, total, &err);
    if (sig == NULL) {
        rb_raise(rb_eObjCError, "cannot build block signature: %s",
                 err ? err : "unknown");
    }

    /* Cheap amortised cleanup of blocks the runtime has already released. */
    reap_dead_blocks();

    block_impl_t *impl = calloc(1, sizeof(block_impl_t));
    if (impl == NULL) rb_raise(rb_eNoMemError, "out of memory");
    impl->sig  = sig;
    impl->proc = rb_block_proc();

    /* Keep the proc alive for exactly as long as the block can be invoked. */
    rb_gc_register_address(&impl->proc);

    void        *code    = NULL;
    ffi_closure *closure = ffi_closure_alloc(sizeof(ffi_closure), &code);
    if (closure == NULL) {
        rb_gc_unregister_address(&impl->proc);
        free(impl);
        rb_raise(rb_eObjCError, "could not allocate an ffi closure");
    }
    impl->closure = closure;

    if (ffi_prep_closure_loc(closure, &sig->cif, block_trampoline,
                             impl, code) != FFI_OK) {
        rb_gc_unregister_address(&impl->proc);
        ffi_closure_free(closure);
        free(impl);
        rb_raise(rb_eObjCError, "ffi_prep_closure_loc failed for block");
    }

    struct block_descriptor *desc = calloc(1, sizeof(struct block_descriptor));
    struct block_layout     *blk  = malloc(sizeof(struct block_layout));
    if (desc == NULL || blk == NULL) rb_raise(rb_eNoMemError, "out of memory");

    desc->reserved  = 0;
    desc->size      = sizeof(struct block_layout);
    desc->copy      = block_copy_helper;
    desc->dispose   = block_dispose_helper;
    desc->signature = build_signature(sig);
    impl->descriptor = desc;

    blk->isa        = (void *)_NSConcreteMallocBlock;
    blk->flags      = BLOCK_NEEDS_FREE | BLOCK_HAS_COPY_DISPOSE |
                      BLOCK_HAS_SIGNATURE | BLOCK_ONE_REFERENCE;
    blk->reserved   = 0;
    blk->invoke     = code;
    blk->descriptor = desc;
    blk->impl       = impl;

    impl->next  = block_impls;
    block_impls = impl;
    blocks_live++;

    /* The wrapper adopts the single reference created above. */
    return robjc_wrap_as(rb_cObjCBlock, (id)blk, true);
}

/* ---- Objective-C block -> callable from Ruby ------------------------------ */

/* Recover the signature the compiler stored, walking the optional fields. */
static const char *
block_signature(struct block_layout *blk)
{
    if (blk == NULL || !(blk->flags & BLOCK_HAS_SIGNATURE)) return NULL;

    char *d = (char *)blk->descriptor;
    d += sizeof(unsigned long) * 2;                       /* reserved, size */
    if (blk->flags & BLOCK_HAS_COPY_DISPOSE) {
        d += sizeof(void *) * 2;                          /* copy, dispose */
    }
    return *(const char **)d;
}

static VALUE
rb_objc_block_signature(VALUE self)
{
    const char *sig = block_signature((struct block_layout *)robjc_unwrap(self));
    return sig == NULL ? Qnil : rb_str_new_cstr(sig);
}

static VALUE
rb_objc_block_call(int argc, VALUE *argv, VALUE self)
{
    struct block_layout *blk = (struct block_layout *)robjc_unwrap(self);
    if (blk == NULL) rb_raise(rb_eObjCError, "block is nil");

    const char *sig_str = block_signature(blk);
    if (sig_str == NULL) {
        rb_raise(rb_eObjCError,
                 "this block carries no signature, so it cannot be called");
    }

    const char *err = NULL;
    robjc_sig_t *sig = robjc_sig_for_method(sig_str, &err);
    if (sig == NULL) {
        rb_raise(rb_eObjCError, "cannot parse block signature \"%s\": %s",
                 sig_str, err ? err : "unknown");
    }

    void *self_ptr = blk;
    void *fixed[1] = { &self_ptr };

    return robjc_invoke(blk->invoke, sig, fixed, 1, argc, argv, NULL);
}

static VALUE
rb_objc_block_arity(VALUE self)
{
    const char *sig_str = block_signature((struct block_layout *)robjc_unwrap(self));
    if (sig_str == NULL) return INT2NUM(-1);

    const char *err = NULL;
    robjc_sig_t *sig = robjc_sig_for_method(sig_str, &err);
    if (sig == NULL) return INT2NUM(-1);
    return INT2NUM((int)(sig->nargs > 0 ? sig->nargs - 1 : 0));
}

/* Free any blocks the runtime has released since the last sweep, and report
 * how many are still alive. */
static VALUE
rb_objc_reap_blocks(VALUE mod)
{
    (void)mod;
    reap_dead_blocks();

    VALUE stats = rb_hash_new();
    rb_hash_aset(stats, ID2SYM(rb_intern("live")),   ULONG2NUM(blocks_live));
    rb_hash_aset(stats, ID2SYM(rb_intern("reaped")), ULONG2NUM(blocks_reaped));
    return stats;
}

void
Init_block(void)
{

    rb_cObjCBlock = rb_define_class_under(rb_mObjC, "Block", rb_cObjCObject);
    rb_undef_alloc_func(rb_cObjCBlock);
    rb_define_method(rb_cObjCBlock, "call",      rb_objc_block_call, -1);
    rb_define_method(rb_cObjCBlock, "signature", rb_objc_block_signature, 0);
    rb_define_method(rb_cObjCBlock, "arity",     rb_objc_block_arity, 0);

    rb_define_singleton_method(rb_mObjC, "make_block",  rb_objc_make_block, 2);
    rb_define_singleton_method(rb_mObjC, "reap_blocks", rb_objc_reap_blocks, 0);
}
