/*
 * encoding.c -- Objective-C type encodings -> libffi type descriptions.
 *
 * Encodings come from two places, in the same format:
 *   - method_getTypeEncoding() on a live Method, e.g. "@32@0:8@16"
 *   - Apple's shipped .bridgesupport XML, e.g. type64='{CGRect={CGPoint=dd}...}'
 *
 * Aggregates and whole signatures are memoized, so each distinct encoding is
 * parsed exactly once per process.
 */
#include "rubyobjc.h"
#include <ctype.h>
#include <stdlib.h>
#include <string.h>
#include <ruby/st.h>

/* Permanent caches. Entries live for the life of the process by design: the
 * set of distinct encodings in a program is bounded and small. */
static st_table *sig_cache    = NULL;
static st_table *aggr_cache   = NULL;

const char *
robjc_skip_modifiers(const char *p)
{
    /* r=const n=in N=inout o=out O=bycopy R=byref V=oneway, plus GC hints. */
    while (*p != '\0' && strchr("rnNoORV", *p) != NULL) {
        p++;
    }
    return p;
}

static const char *
skip_digits(const char *p)
{
    while (isdigit((unsigned char)*p)) {
        p++;
    }
    return p;
}

const char *
robjc_skip_type(const char *p)
{
    p = robjc_skip_modifiers(p);
    switch (*p) {
      case '\0':
        return p;
      case '^':
        return robjc_skip_type(p + 1);
      case '@':
        /* "@?" is a block or function pointer: two characters, one type. */
        return (p[1] == '?') ? p + 2 : p + 1;
      case 'b':                        /* bitfield: bN */
        return skip_digits(p + 1);
      case '[': {                      /* array: [N type] */
        p = skip_digits(p + 1);
        p = robjc_skip_type(p);
        if (*p == ']') p++;
        return p;
      }
      case '{': case '(': {
        char close = (*p == '{') ? '}' : ')';
        p++;
        while (*p != '\0' && *p != '=' && *p != close) p++;   /* struct name */
        if (*p == '=') {
            p++;
            while (*p != '\0' && *p != close) {
                if (*p == '"') {                 /* quoted field name */
                    p++;
                    while (*p != '\0' && *p != '"') p++;
                    if (*p == '"') p++;
                    continue;
                }
                p = robjc_skip_type(p);
            }
        }
        if (*p == close) p++;
        return p;
      }
      default:
        return p + 1;
    }
}

/* Assemble a libffi struct type from a NULL-terminated element list and let
 * libffi compute size and alignment for the current ABI. */
static ffi_type *
make_aggregate(ffi_type **elements)
{
    ffi_type *t = malloc(sizeof(ffi_type));
    if (t == NULL) {
        rb_raise(rb_eNoMemError, "out of memory building struct type");
    }
    t->size      = 0;
    t->alignment = 0;
    t->type      = FFI_TYPE_STRUCT;
    t->elements  = elements;
    /* Populates t->size / t->alignment as a side effect. */
    ffi_get_struct_offsets(FFI_DEFAULT_ABI, t, NULL);
    return t;
}

static ffi_type *
parse_aggregate(const char **pp)
{
    const char *start = *pp;
    const char *p     = start;
    char        close = (*p == '{') ? '}' : ')';
    bool        is_union = (*p == '(');

    /* Memoize on the exact encoding substring. */
    const char *end = robjc_skip_type(start);
    size_t      len = (size_t)(end - start);
    char       *key = malloc(len + 1);
    if (key == NULL) rb_raise(rb_eNoMemError, "out of memory");
    memcpy(key, start, len);
    key[len] = '\0';

    if (aggr_cache == NULL) aggr_cache = st_init_strtable();
    st_data_t hit;
    if (st_lookup(aggr_cache, (st_data_t)key, &hit)) {
        free(key);
        *pp = end;
        return (ffi_type *)hit;
    }

    p++;
    while (*p != '\0' && *p != '=' && *p != close) p++;   /* skip struct name */

    size_t     cap = 8, n = 0;
    ffi_type **elems = malloc(sizeof(ffi_type *) * (cap + 1));
    if (elems == NULL) { free(key); rb_raise(rb_eNoMemError, "out of memory"); }

    if (*p == '=') {
        p++;
        while (*p != '\0' && *p != close) {
            if (*p == '"') {                     /* bridgesupport field names */
                p++;
                while (*p != '\0' && *p != '"') p++;
                if (*p == '"') p++;
                continue;
            }
            ffi_type *ft = robjc_ffi_type_for(&p);
            if (ft == NULL) break;
            if (ft == &ffi_type_void) continue;  /* opaque padding, ignore */
            if (n == cap) {
                cap *= 2;
                elems = realloc(elems, sizeof(ffi_type *) * (cap + 1));
                if (elems == NULL) { free(key); rb_raise(rb_eNoMemError, "out of memory"); }
            }
            elems[n++] = ft;
        }
    }

    /* A union is approximated by its widest member: same size and alignment
     * for call purposes, which is all libffi needs. */
    if (is_union && n > 1) {
        ffi_type *widest = elems[0];
        for (size_t i = 1; i < n; i++) {
            if (elems[i]->size > widest->size) widest = elems[i];
        }
        elems[0] = widest;
        n = 1;
    }

    elems[n] = NULL;

    /* An empty or opaque struct still needs a byte so offsets stay sane. */
    if (n == 0) {
        elems[0] = &ffi_type_uint8;
        elems[1] = NULL;
    }

    ffi_type *t = make_aggregate(elems);
    st_insert(aggr_cache, (st_data_t)key, (st_data_t)t);
    *pp = end;
    return t;
}

ffi_type *
robjc_ffi_type_for(const char **pp)
{
    const char *p = robjc_skip_modifiers(*pp);

    switch (*p) {
      case 'c': *pp = p + 1; return &ffi_type_sint8;
      case 'C': *pp = p + 1; return &ffi_type_uint8;
      case 's': *pp = p + 1; return &ffi_type_sint16;
      case 'S': *pp = p + 1; return &ffi_type_uint16;
      case 'i': *pp = p + 1; return &ffi_type_sint32;
      case 'I': *pp = p + 1; return &ffi_type_uint32;
      /* 'l'/'L' are explicitly 32-bit in the ObjC encoding, even on LP64. */
      case 'l': *pp = p + 1; return &ffi_type_sint32;
      case 'L': *pp = p + 1; return &ffi_type_uint32;
      case 'q': *pp = p + 1; return &ffi_type_sint64;
      case 'Q': *pp = p + 1; return &ffi_type_uint64;
      case 'f': *pp = p + 1; return &ffi_type_float;
      case 'd': *pp = p + 1; return &ffi_type_double;
      case 'D': *pp = p + 1; return &ffi_type_longdouble;
      case 'B': *pp = p + 1; return &ffi_type_uint8;   /* _Bool */
      case 'v': *pp = p + 1; return &ffi_type_void;

      case '@':                                        /* id, or "@?" block */
        *pp = (p[1] == '?') ? p + 2 : p + 1;
        return &ffi_type_pointer;

      case '*':                                        /* char *    */
      case '#':                                        /* Class     */
      case ':':                                        /* SEL       */
      case '?':                                        /* unknown/fn ptr */
        *pp = p + 1;
        return &ffi_type_pointer;

      case '^':                                        /* pointer to ... */
        *pp = robjc_skip_type(p + 1);
        return &ffi_type_pointer;

      case 'b':                                        /* bitfield */
        *pp = skip_digits(p + 1);
        return &ffi_type_uint32;

      case '[': {                                      /* array by value */
        const char *q = skip_digits(p + 1);
        long count = strtol(p + 1, NULL, 10);
        const char *elem_start = q;
        ffi_type *elem = robjc_ffi_type_for(&q);
        (void)elem_start;
        if (*q == ']') q++;
        *pp = q;
        if (count <= 0 || elem == NULL) return &ffi_type_pointer;

        ffi_type **elems = malloc(sizeof(ffi_type *) * ((size_t)count + 1));
        if (elems == NULL) rb_raise(rb_eNoMemError, "out of memory");
        for (long i = 0; i < count; i++) elems[i] = elem;
        elems[count] = NULL;
        return make_aggregate(elems);
      }

      case '{':
      case '(':
        return parse_aggregate(pp);

      default:
        /* Unrecognised: consume one char and treat as pointer-sized. */
        *pp = p + 1;
        return &ffi_type_pointer;
    }
}

ffi_type *
robjc_ffi_type_parse(const char *enc)
{
    const char *p = enc;
    return robjc_ffi_type_for(&p);
}

static char *
dup_range(const char *start, const char *end)
{
    size_t len = (size_t)(end - start);
    char  *s   = malloc(len + 1);
    if (s == NULL) rb_raise(rb_eNoMemError, "out of memory");
    memcpy(s, start, len);
    s[len] = '\0';
    return s;
}

/*
 * Decide whether a struct return needs objc_msgSend_stret.
 *
 * arm64 has no _stret variant at all: large returns use the indirect result
 * register and libffi handles that transparently. On x86_64 the SysV rule that
 * matters in practice for Cocoa is "larger than 16 bytes goes via memory",
 * which is what objc_msgSend_stret implements. CGRect (32 bytes) needs it;
 * CGPoint and CGSize (16 bytes) do not.
 */
static bool
needs_stret(ffi_type *rtype)
{
#if defined(__x86_64__)
    return rtype != NULL && rtype->type == FFI_TYPE_STRUCT && rtype->size > 16;
#else
    (void)rtype;
    return false;
#endif
}

static robjc_sig_t *
finish_sig(robjc_sig_t *sig, const char **err)
{
    ffi_status st = ffi_prep_cif(&sig->cif, FFI_DEFAULT_ABI, sig->nargs,
                                 sig->rtype, sig->atypes);
    if (st != FFI_OK) {
        *err = "ffi_prep_cif failed for this signature";
        return NULL;
    }
    sig->use_stret = needs_stret(sig->rtype);
    return sig;
}

robjc_sig_t *
robjc_sig_for_method(const char *enc, const char **err)
{
    *err = NULL;
    if (enc == NULL || *enc == '\0') {
        *err = "empty method type encoding";
        return NULL;
    }

    if (sig_cache == NULL) sig_cache = st_init_strtable();
    st_data_t hit;
    if (st_lookup(sig_cache, (st_data_t)enc, &hit)) {
        return (robjc_sig_t *)hit;
    }

    const char *p = enc;

    /* Return type, then the frame size digits. */
    const char *rstart = robjc_skip_modifiers(p);
    const char *rend   = robjc_skip_type(rstart);
    char       *ret_enc = dup_range(rstart, rend);
    const char *scan   = skip_digits(rend);

    /* Count arguments (self and _cmd included). */
    unsigned int count = 0;
    const char  *cscan = scan;
    while (*cscan != '\0') {
        const char *next = robjc_skip_type(cscan);
        if (next == cscan) break;
        count++;
        cscan = skip_digits(next);
    }

    robjc_sig_t *sig = calloc(1, sizeof(robjc_sig_t));
    if (sig == NULL) { free(ret_enc); rb_raise(rb_eNoMemError, "out of memory"); }

    sig->nargs   = count;
    sig->ret_enc = ret_enc;
    sig->rtype   = robjc_ffi_type_parse(ret_enc);
    sig->atypes  = calloc(count > 0 ? count : 1, sizeof(ffi_type *));
    sig->arg_enc = calloc(count > 0 ? count : 1, sizeof(char *));
    if (sig->atypes == NULL || sig->arg_enc == NULL) {
        rb_raise(rb_eNoMemError, "out of memory");
    }

    unsigned int i = 0;
    while (*scan != '\0' && i < count) {
        const char *astart = robjc_skip_modifiers(scan);
        const char *aend   = robjc_skip_type(astart);
        if (aend == astart) break;
        sig->arg_enc[i] = dup_range(astart, aend);
        sig->atypes[i]  = robjc_ffi_type_parse(sig->arg_enc[i]);
        i++;
        scan = skip_digits(aend);
    }
    sig->nargs = i;

    if (finish_sig(sig, err) == NULL) return NULL;

    st_insert(sig_cache, (st_data_t)strdup(enc), (st_data_t)sig);
    return sig;
}

robjc_sig_t *
robjc_sig_for_function(const char *ret_enc, const char **arg_encs,
                       unsigned int nargs, const char **err)
{
    *err = NULL;

    robjc_sig_t *sig = calloc(1, sizeof(robjc_sig_t));
    if (sig == NULL) rb_raise(rb_eNoMemError, "out of memory");

    sig->nargs   = nargs;
    sig->ret_enc = strdup(ret_enc);
    sig->rtype   = robjc_ffi_type_parse(ret_enc);
    sig->atypes  = calloc(nargs > 0 ? nargs : 1, sizeof(ffi_type *));
    sig->arg_enc = calloc(nargs > 0 ? nargs : 1, sizeof(char *));
    if (sig->atypes == NULL || sig->arg_enc == NULL) {
        rb_raise(rb_eNoMemError, "out of memory");
    }

    for (unsigned int i = 0; i < nargs; i++) {
        sig->arg_enc[i] = strdup(arg_encs[i]);
        sig->atypes[i]  = robjc_ffi_type_parse(arg_encs[i]);
    }

    return finish_sig(sig, err);
}
