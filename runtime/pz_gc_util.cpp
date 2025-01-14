/*
 * Plasma GC rooting, scopes & C++ allocation utilities
 * vim: ts=4 sw=4 et
 *
 * Copyright (C) 2018-2021 Plasma Team
 * Distributed under the terms of the MIT license, see ../LICENSE.code
 */

#include "pz_common.h"

#include "pz_util.h"

#include "pz_gc.h"
#include "pz_gc_util.h"

#include "pz_gc.impl.h"

namespace pz {

void * GCCapability::alloc(size_t size_in_words, AllocOpts opts)
{
#ifdef PZ_DEV
    assert(m_is_top);
#endif
    return m_heap.alloc(size_in_words, *this, opts);
}

void * GCCapability::alloc_bytes(size_t size_in_bytes, AllocOpts opts)
{
#ifdef PZ_DEV
    assert(m_is_top);
#endif
    return m_heap.alloc_bytes(size_in_bytes, *this, opts);
}

const AbstractGCTracer & GCCapability::tracer() const
{
    assert(can_gc());
    return *static_cast<const AbstractGCTracer *>(this);
}

bool GCCapability::can_gc() const
{
    const GCCapability *cur = this;

    do {
        switch (cur->m_can_gc) {
          case IS_ROOT:
            assert(!cur->m_parent);
            // If this is the root, then we cannot GC because we cannot call
            // trace() on this GCCapability.
            return this != cur;
          case CANNOT_GC:
            return false;
          case CAN_GC:
            break;
        }
        cur = cur->m_parent;
    } while (cur);

    return true;
}

static void abort_oom(size_t size_bytes)
{
    fprintf(
        stderr, "Out of memory, tried to allocate %lu bytes.\n", size_bytes);
    abort();
}

void GCCapability::trace_parent(HeapMarkState * state) const {
    if (m_parent && m_parent->can_gc()) {
        m_parent->tracer().do_trace(state);
    }
}

void GCThreadHandle::oom(size_t size_bytes)
{
    abort_oom(size_bytes);
}

void AbstractGCTracer::oom(size_t size_bytes)
{
    abort_oom(size_bytes);
}

void GCTracer::do_trace(HeapMarkState * state) const
{
    for (void * root : m_roots) {
        state->mark_root(*(void **)root);
    }

    trace_parent(state);
}

void GCTracer::add_root(void * root)
{
    m_roots.push_back(root);
}

void GCTracer::remove_root(void * root)
{
    assert(!m_roots.empty());
    assert(m_roots.back() == root);
    m_roots.pop_back();
}

NoGCScope::NoGCScope(GCCapability & gc_cap)
    : GCCapability(gc_cap, CANNOT_GC)
#ifdef PZ_DEV
    , m_needs_check(true)
#endif
    , m_did_oom(false)
{ }

NoGCScope::~NoGCScope()
{
#ifdef PZ_DEV
    if (m_needs_check) {
        fprintf(
            stderr,
            "Caller did not check the NoGCScope before the destructor ran.\n");
        abort();
    }
#endif

    if (m_did_oom) {
        fprintf(stderr,
                "Out of memory, tried to allocate %lu bytes.\n",
                m_oom_size);
        abort();
    }
}

void NoGCScope::oom(size_t size_bytes)
{
    if (!m_did_oom) {
        m_did_oom  = true;
        m_oom_size = size_bytes;
    }
}

void NoGCScope::abort_for_oom_slow(const char * label)
{
    assert(m_did_oom);
    fprintf(stderr,
            "Out of memory while %s, tried to allocate %ld bytes.\n",
            label,
            m_oom_size);
    abort();
}

/****************************************************************************/

static void * do_new(size_t size, GCCapability & gc_cap, AllocOpts opts);

/*
 * This is not exactly conformant to C++ normals/contracts.  It doesn't call
 * the new handler when allocation fails which is what should normally
 * happen.  However the GC's alloc_bytes function already makes an attempt to
 * recover memory via the GCCapability parameter.
 *
 * See: Scott Meyers: Effective C++ Digital Collection, Item 51 regarding
 * this behaviour.
 */
void * GCNew::operator new(size_t size, GCCapability & gc_cap)
{
    return do_new(size, gc_cap, NORMAL);
}

void * GCNewTrace::operator new(size_t size, GCCapability & gc_cap)
{
    return do_new(size, gc_cap, TRACE);
}

static void * do_new(size_t size, GCCapability & gc_cap, AllocOpts opts)
{
    if (0 == size) {
        size = 1;
    }

    void * mem = gc_cap.alloc_bytes(size, opts);
    if (!mem) {
        fprintf(stderr, "Out of memory in operator new!\n");
        abort();
    }

    return mem;
}

}  // namespace pz

void * operator new[](size_t size, pz::GCCapability & gc_cap)
{
    return pz::do_new(size, gc_cap, pz::NORMAL);
}
