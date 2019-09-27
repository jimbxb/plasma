/*
 * Plasma garbage collector
 * vim: ts=4 sw=4 et
 *
 * Copyright (C) 2018-2019 Plasma Team
 * Distributed under the terms of the MIT license, see ../LICENSE.code
 */

#include "pz_common.h"

#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "pz_util.h"

#include "pz_gc.h"
#include "pz_gc_util.h"

#include "pz_gc.impl.h"
#include "pz_gc_layout.h"
#include "pz_gc_layout.impl.h"

/*
 * Plasma GC
 * ---------
 *
 * We want a GC that provides enough features to meet some MVP-ish goals.  It
 * only needs to be good enough to ensure we recover memory.  It is
 * currently a little bit better than that.
 *
 *  * Mark/Sweep
 *  * Non-moving
 *  * Conservative
 *  * Interior pointers (up to 7 byte offset)
 *  * Block based, each block contains cells of a particular size, a marking
 *    bitmap and free list pointer (the free list is made of unused cell
 *    contents.
 *  * Blocks are allocated from Chunks.  We allocate chunks from the OS.
 *
 * This is about the simplest GC one could imagine, it is very naive in the
 * short term we should:
 *
 *  * Support larger allocations:
 *    https://github.com/PlasmaLang/plasma/issues/188
 *  * Use a mark stack
 *  * Tune "when to collect" decision.
 *  * Plus other open bugs in the bugtracker:
 *    https://github.com/PlasmaLang/plasma/labels/component%3A%20gc
 *
 * In the slightly longer term we should:
 *
 *  * Use accurate pointer information and test it by adding compaction.
 *
 * In the long term, and with much tweaking, this GC will become the
 * tenured and maybe the tenured/mutable part of a larger GC with more
 * features and improvements.
 */

namespace pz {

/***************************************************************************
 *
 * These procedures will likely move somewhere else, but maybe after some
 * refactoring.
 */

size_t
heap_get_max_size(const Heap *heap)
{
    return heap->max_size();
}

bool
heap_set_max_size(Heap *heap, size_t new_size)
{
    return heap->set_max_size(new_size);
}

size_t
heap_get_size(const Heap *heap)
{
    return heap->size();
}

unsigned
heap_get_collections(const Heap *heap)
{
    return heap->collections();
}

bool
ChunkBOP::is_empty() const
{
    for (unsigned i = 0; i < m_wilderness; i++) {
        if (m_blocks[i].is_in_use()) return false;
    }
    return true;
}

bool Heap::is_empty() const
{
    return m_chunk_bop == nullptr || m_chunk_bop->is_empty();
}

/***************************************************************************/

size_t Heap::s_page_size;

void Heap::init_statics()
{
    if (s_page_size == 0) {
        s_page_size = sysconf(_SC_PAGESIZE);
        assert(s_page_size != 0);
    }
}

Heap::Heap(const Options &options_, AbstractGCTracer &trace_global_roots_)
        : m_options(options_)
        , m_chunk_bop(nullptr)
        , m_chunk_fit(nullptr)
        , m_max_size(GC_Heap_Size)
        , m_collections(0)
        , m_trace_global_roots(trace_global_roots_)
#ifdef PZ_DEV
        , m_in_no_gc_scope(false)
#endif
{ }

Heap::~Heap()
{
    // Check that finalise was called.
    assert(!m_chunk_bop);
    assert(!m_chunk_fit);
}

bool
Heap::init()
{
    init_statics();

    assert(!m_chunk_bop);
    Chunk *chunk = Chunk::new_chunk();
    if (chunk) {
        m_chunk_bop = chunk->initalise_as_bop();
    } else {
        return false;
    }

    assert(!m_chunk_fit);
    chunk = Chunk::new_chunk();
    if (chunk) {
        m_chunk_fit = chunk->initalise_as_fit();
    } else {
        return false;
    }

    return true;
}

Chunk*
Chunk::new_chunk()
{
    Chunk *chunk;

    chunk = static_cast<Chunk*>(mmap(NULL, GC_Chunk_Size,
            PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    if (MAP_FAILED == chunk) {
        perror("mmap");
        return nullptr;
    }

    new(chunk) Chunk();

    return chunk;
}

bool
Chunk::destroy() {
    if (-1 == munmap(this, GC_Chunk_Size)) {
        perror("munmap");
        return false;
    }

    return true;
}

ChunkBOP*
Chunk::initalise_as_bop()
{
    assert(m_type == CT_INVALID);
    ChunkBOP *chunk_bop = reinterpret_cast<ChunkBOP*>(this);
    new(chunk_bop) ChunkBOP();
    return chunk_bop;
}

ChunkFit*
Chunk::initalise_as_fit()
{
    assert(m_type == CT_INVALID);
    ChunkFit *chunk_fit = reinterpret_cast<ChunkFit*>(this);
    new(chunk_fit) ChunkFit();
    return chunk_fit;
}

bool
Heap::finalise()
{
    bool result = true;

    if (m_chunk_bop) {
        if (!m_chunk_bop->destroy()) {
            result = false;
        }
        m_chunk_bop = nullptr;
    }

    if (m_chunk_fit) {
        if (!m_chunk_fit->destroy()) {
            result = false;
        }
        m_chunk_fit = nullptr;
    }

    return result;
}

/***************************************************************************/

Block::Block(const Options &options, size_t cell_size_) :
        m_header(cell_size_)
{
    assert(cell_size_ >= GC_Min_Cell_Size);
    memset(m_header.bitmap, 0, GC_Cells_Per_Block * sizeof(uint8_t));

#if PZ_DEV
    if (options.gc_poison()) {
        memset(m_bytes, Poison_Byte, Payload_Bytes);
    }
#endif

    sweep(options);
}

/***************************************************************************/

bool
Heap::set_max_size(size_t new_size)
{
    assert(s_page_size != 0);
    if (new_size < s_page_size) return false;

    if (new_size % sizeof(Block) != 0) return false;

    if (new_size < m_chunk_bop->size()) return false;

#ifdef PZ_DEV
    if (m_options.gc_trace()) {
        fprintf(stderr, "New heap size: %ld\n", new_size);
    }
#endif

    m_max_size = new_size;
    return true;
}

size_t
Heap::size() const
{
    if (m_chunk_bop) {
        return m_chunk_bop->size();
    } else {
        return 0;
    }
}

size_t
ChunkBOP::size() const
{
    size_t num_blocks = 0;

    for (unsigned i = 0; i < m_wilderness; i++) {
        if (m_blocks[i].is_in_use()) {
            num_blocks += 1;
        }
    }

    return num_blocks * GC_Block_Size;
}

/***************************************************************************/

#ifdef PZ_DEV
void
Heap::start_no_gc_scope()
{
    assert(!m_in_no_gc_scope);
    m_in_no_gc_scope = true;
}

void
Heap::end_no_gc_scope()
{
    assert(m_in_no_gc_scope);
    m_in_no_gc_scope = false;
}
#endif

/***************************************************************************/

#ifdef PZ_DEV
void
Heap::print_usage_stats() const
{
    m_chunk_bop->print_usage_stats();
}

void
ChunkBOP::print_usage_stats() const
{
    printf("\nBBLOCK\n------\n");
    printf("Num blocks: %d/%ld, %ldKB\n",
        m_wilderness, GC_Block_Per_Chunk,
        m_wilderness * GC_Block_Size / 1024);
    for (unsigned i = 0; i < m_wilderness; i++) {
        m_blocks[i].print_usage_stats();
    }
}

void
Block::print_usage_stats() const
{
    if (is_in_use()) {
        unsigned cells_used = 0;
        for (unsigned i = 0; i < num_cells(); i++) {
            CellPtrBOP cell(const_cast<Block*>(this), i);
            if (is_allocated(cell)) {
                cells_used++;
            }
        }
        printf("Lblock for %ld-word objects: %d/%d cells\n",
            size(), cells_used, num_cells());
    } else {
        printf("Lblock out of use\n");
    }
}

#endif

} // namespace pz

/***************************************************************************
 *
 * Check arhitecture assumptions
 */

// 8 bits per byte
static_assert(WORDSIZE_BYTES * 8 == WORDSIZE_BITS);

// 32 or 64 bit.
static_assert(WORDSIZE_BITS == 64 || WORDSIZE_BITS == 32);

