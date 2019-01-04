/*
 * Plasma garbage collector
 * vim: ts=4 sw=4 et
 *
 * Copyright (C) 2018 Plasma Team
 * Distributed under the terms of the MIT license, see ../LICENSE.code
 */

#include "pz_common.h"

#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "pz_util.h"

#include "pz_gc.h"

/*
 * Plasma GC
 * ---------
 *
 * We want a GC that provides enough features to meet some MVP-ish goals.  It
 * only needs to be good enough to ensure we recover memory.  We'll re-write it
 * in later stages of the project.
 *
 *  * Mark/Sweep
 *  * Non-moving
 *  * Conservative
 *  * Interior pointers (up to 7 byte offset)
 *  * Allocate from free lists otherwise bump-pointer into wilderness.
 *  * Cell sizes are stored in the word before each cell.
 *  * Each word has an associated byte which stores whether it is the
 *    beginning of an allocation and/or marked.  The mark bit only makes
 *    sense if the object _is_ the beginning of an allocation.
 *
 * This is about the simplest GC one could imagine, it is very naive in the
 * short term we should:
 *
 *  * Sort the free list or use multiple free lists to speed up allocation.
 *  * Use a mark stack
 *  * Tune "when to collect" decision.
 *
 * In the slightly longer term we should:
 *
 *  * Use a BIBOP heap layout, generally saving memory.
 *  * Use accurate pointer information and test it by adding compaction.
 *
 * In the long term, and with much tweaking, this GC will become the
 * tenured and maybe the tenured/mutable part of a larger GC with more
 * features and improvements.
 */

#define PZ_GC_MAX_HEAP_SIZE ((1024*1024))
#define PZ_GC_HEAP_SIZE 4096

/*
 * Mask off the low bits so that we can see the real pointer rather than a
 * tagged pointer.
 */
#if __WORDSIZE == 64
#define TAG_BITS 0x7
#elif __WORDSIZE == 32
#define TAG_BITS 0x3
#endif

#define REMOVE_TAG(x) (void*)((uintptr_t)(x) & (~(uintptr_t)0 ^ TAG_BITS))

#define GC_BITS_ALLOCATED 0x01
#define GC_BITS_MARKED    0x02
#define GC_BITS_VALID     0x04

namespace pz {

static size_t
page_size;
static bool
statics_initalised = false;

/***************************************************************************/

Heap::Heap(const Options &options_, void *stack_)
        : options(options_)
        , base_address(nullptr)
        , heap_size(PZ_GC_HEAP_SIZE)
        , wilderness_ptr(nullptr)
        , free_list(nullptr)
        , stack(stack_)
{
    // TODO: This array doesn't need to be this big.
    // Use std::vector and allow it to change size as the heap size changes.
    // and also catch out-of-bounds access.
    bitmap = new uint8_t[PZ_GC_MAX_HEAP_SIZE / MACHINE_WORD_SIZE];
    memset(bitmap, 0, PZ_GC_MAX_HEAP_SIZE / MACHINE_WORD_SIZE);
}

Heap::~Heap()
{
    // Check that finalise was called.
    assert(!base_address);

    delete[] bitmap;
}

bool
Heap::init()
{
    if (!statics_initalised) {
        statics_initalised = true;
        page_size = sysconf(_SC_PAGESIZE);
    }

    base_address = mmap(NULL, PZ_GC_MAX_HEAP_SIZE,
            PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (MAP_FAILED == base_address) {
        perror("mmap");
        return false;
    }

    wilderness_ptr = base_address;

    return true;
}

bool
Heap::finalise()
{
    if (!base_address)
        return true;

    bool result = -1 != munmap(base_address, PZ_GC_MAX_HEAP_SIZE);
    if (!result) {
        perror("munmap");
    }

    base_address = nullptr;
    wilderness_ptr = nullptr;
    return result;
}

/***************************************************************************/

void *
Heap::alloc(size_t size_in_words, void *top_of_stack)
{
    assert(size_in_words > 0);

    void *cell;
#ifdef PZ_DEV
    if (options.gc_zealous() && wilderness_ptr > base_address) {
        // Force a collect before each allocation in this mode.
        cell = NULL;
    } else
#endif
    {
        cell = try_allocate(size_in_words);
    }
    if (cell == NULL) {
        collect(top_of_stack);
        cell = try_allocate(size_in_words);
        if (cell == NULL) {
            fprintf(stderr, "Out of memory, tried to allocate %lu bytes\n",
                        size_in_words * MACHINE_WORD_SIZE);
            abort();
        }
    }

    return cell;
}

void *
Heap::alloc_bytes(size_t size_in_bytes, void *top_of_stack)
{
    size_t size_in_words = ALIGN_UP(size_in_bytes, MACHINE_WORD_SIZE) /
        MACHINE_WORD_SIZE;

    return alloc(size_in_words, top_of_stack);
}

void *
Heap::try_allocate(size_t size_in_words)
{
    void **cell;

    /*
     * Try the free list
     */
    void **best = NULL;
    void **prev_best = NULL;
    void **prev_cell = NULL;
    cell = free_list;
    while (cell != NULL) {
        assert(*cell_bits(cell) == GC_BITS_VALID);

        assert(*cell_size(cell) != 0);
        if (*cell_size(cell) >= size_in_words) {
            if (best == NULL) {
                prev_best = prev_cell;
                best = cell;
            } else if (*cell_size(cell) < *cell_size(best)) {
                prev_best = prev_cell;
                best = cell;
            }
        }

        prev_cell = cell;
        cell = static_cast<void**>(*cell);
    }
    if (best != NULL) {
        // Unlink the cell from the free list.
        if (prev_best == NULL) {
            assert(free_list == best);
            free_list = static_cast<void**>(*best);
        } else {
            *prev_best = *best;
        }

        // Mark as allocated
        assert(*cell_bits(best) == GC_BITS_VALID);
        *cell_bits(best) = GC_BITS_VALID | GC_BITS_ALLOCATED;

        if (*cell_size(best) >= size_in_words + 2) {
            // This cell is bigger than we need, so shrink it.
            unsigned old_size = *cell_size(best);

            // Assert that the cell after this one is valid.
            assert((best + old_size == wilderness_ptr) ||
                    (*cell_bits(best + old_size + 1) & GC_BITS_VALID));

            *cell_size(best) = size_in_words;
            void** next_cell = best + size_in_words + 1;
            *cell_size(next_cell) = old_size - (size_in_words + 1);
            *cell_bits(next_cell) = GC_BITS_VALID;
            *next_cell = free_list;
            free_list = next_cell;
            #ifdef PZ_DEV
            if (options.gc_trace()) {
                fprintf(stderr, "Split cell %p from %u into %lu and %u\n",
                    best, old_size, size_in_words,
                    (unsigned)*cell_size(next_cell));
            }
            #endif
        }
        #ifdef PZ_DEV
        if (options.gc_trace2()) {
            fprintf(stderr, "Allocated %p from free list\n", best);
        }
        #endif
        return best;
    }

    /*
     * We also allocate the word before cell and store it's size there.
     */
    cell = static_cast<void**>(wilderness_ptr + MACHINE_WORD_SIZE);

    void *new_wilderness_ptr = wilderness_ptr +
        (size_in_words + 1)*MACHINE_WORD_SIZE;
    if (new_wilderness_ptr > base_address + heap_size) return nullptr;

    wilderness_ptr = new_wilderness_ptr;
    assert(*cell_size(cell) == 0);
    *cell_size(cell) = size_in_words;

    /*
     * Each cell is a pointer to 'size' bytes of memory.  The "allocated" bit
     * is set for the memory word corresponding to 'cell'.
     */
    assert(*cell_bits(cell) == 0);
    *cell_bits(cell) = GC_BITS_ALLOCATED | GC_BITS_VALID;

    #ifdef PZ_DEV
    if (options.gc_trace2()) {
        fprintf(stderr, "Allocated %p from the wilderness\n", cell);
    }
    #endif

    return cell;
}

/***************************************************************************/

void
Heap::collect(void *top_of_stack)
{
    unsigned num_roots_marked = 0;
    unsigned num_marked = 0;

    #ifdef PZ_DEV
    if (options.gc_slow_asserts()) {
        check_heap();
    }
    #endif

    // Mark from the root objects.
    for (void **p_cur = (void**)stack;
         p_cur <= (void**)top_of_stack;
         p_cur++)
    {
        void *cur = REMOVE_TAG(*p_cur);
        if (is_valid_object(cur) &&
                !(*cell_bits(cur) & GC_BITS_MARKED))
        {
            num_marked += mark(static_cast<void**>(cur));
            num_roots_marked++;
        }
    }
    #ifdef PZ_DEV
    if (options.gc_trace()) {
        fprintf(stderr,
                "Marked %d out of %ld root pointers, "
                    "marked %u pointers total\n",
                num_roots_marked,
                (uintptr_t(top_of_stack) - uintptr_t(stack)) /
                    MACHINE_WORD_SIZE,
                num_marked);
    }
    #endif

    sweep();

    #ifdef PZ_DEV
    if (options.gc_slow_asserts()) {
        check_heap();
    }
    #endif
}

unsigned
Heap::mark(void **ptr)
{
    unsigned size = *cell_size(ptr);
    unsigned num_marked = 0;

    *cell_bits(ptr) |= GC_BITS_MARKED;
    num_marked++;

    for (void **p_cur = ptr; p_cur < ptr + size; p_cur++) {
        void *cur = REMOVE_TAG(*p_cur);
        if (is_valid_object(cur) &&
                !(*cell_bits(cur) & GC_BITS_MARKED))
        {
            num_marked += mark(static_cast<void**>(cur));
        }
    }

    return num_marked;
}

void
Heap::sweep()
{
    // Sweep
    free_list = NULL;
    unsigned num_checked = 0;
    unsigned num_swept = 0;
    unsigned num_merged = 0;
    void **p_cell = (void**)base_address + 1;
    void **p_first_in_run = NULL;
    while (p_cell < (void**)wilderness_ptr)
    {
        assert(is_heap_address(p_cell));
        assert(*cell_size(p_cell) != 0);
        assert(*cell_bits(p_cell) & GC_BITS_VALID);
        unsigned old_size = *cell_size(p_cell);

        num_checked++;
        if (!(*cell_bits(p_cell) & GC_BITS_MARKED)) {
#ifdef PZ_DEV
            // Poison the cell.
            if (options.gc_poison()) {
                memset(p_cell, 0x77, old_size * MACHINE_WORD_SIZE);
            }
#endif
            if (p_first_in_run == NULL) {
                // Add to free list.
                *p_cell = free_list;
                free_list = p_cell;

                // Clear allocated bit
                *cell_bits(p_cell) &= ~GC_BITS_ALLOCATED;

                p_first_in_run = p_cell;
            } else {
                // Clear valid bit, this cell will be merged.
                *cell_bits(p_cell) = 0;
#ifdef PZ_DEV
                // poison the size field.
                if (options.gc_poison()) {
                    memset(cell_size(p_cell), 0x77, MACHINE_WORD_SIZE);
                }
#endif
                num_merged++;
            }

            assert(p_cell + old_size <= (void**)wilderness_ptr);
            assert((p_cell + old_size == wilderness_ptr) ||
                (*cell_bits(p_cell + old_size + 1) & GC_BITS_VALID));

            #ifdef PZ_DEV
            if (options.gc_trace2()) {
                fprintf(stderr, "Swept %p\n", p_cell);
            }
            #endif
            num_swept++;
        } else {
            assert(*cell_bits(p_cell) & GC_BITS_ALLOCATED);
            // Clear mark bit
            *cell_bits(p_cell) &= ~GC_BITS_MARKED;

            if (p_first_in_run != NULL) {
                // fixup size
                *cell_size(p_first_in_run) = p_cell - 1 - p_first_in_run;
                p_first_in_run = NULL;
            }
        }

        p_cell = p_cell + old_size + 1;
    }

    if (p_first_in_run != NULL) {
        // fixup size
        *cell_size(p_first_in_run) = (void**)wilderness_ptr -
            p_first_in_run;
        p_first_in_run = NULL;
    }

#ifdef PZ_DEV
    if (options.gc_trace()) {
        fprintf(stderr, "%u/%u cells swept (%u merged)\n",
                num_swept, num_checked, num_merged);
    }
#endif
}

/***************************************************************************/

bool
Heap::set_heap_size(size_t new_size)
{
    assert(statics_initalised);
    if (new_size < page_size) return false;
    if (base_address + new_size < wilderness_ptr) return false;

#ifdef PZ_DEV
    if (options.gc_trace()) {
        fprintf(stderr, "New heap size: %ld\n", new_size);
    }
#endif

    heap_size = new_size;
    return true;
}

/***************************************************************************/

bool
Heap::is_valid_object(void *ptr)
{
    bool valid = is_heap_address(ptr) &&
        ((*cell_bits(ptr) & (GC_BITS_ALLOCATED | GC_BITS_VALID)) ==
            (GC_BITS_ALLOCATED | GC_BITS_VALID));

    if (valid) {
        assert(*cell_size(ptr) != 0);
    }

    return valid;
}

bool
Heap::is_heap_address(void *ptr)
{
    return ptr >= base_address && ptr < wilderness_ptr;
}

uint8_t*
Heap::cell_bits(void *ptr)
{
    assert(is_heap_address(ptr));
    unsigned index = ((uintptr_t)ptr - (uintptr_t)base_address) /
        MACHINE_WORD_SIZE;

    return &bitmap[index];
}

uintptr_t *
Heap::cell_size(void *p_cell)
{
    return ((uintptr_t*)p_cell) - 1;
}

/***************************************************************************/

#ifdef PZ_DEV
void
Heap::check_heap()
{
    assert(statics_initalised);
    assert(base_address != NULL);
    assert(heap_size >= page_size);
    assert(heap_size % page_size == 0);
    assert(bitmap);
    assert(wilderness_ptr != NULL);
    assert(base_address < wilderness_ptr);
    assert(wilderness_ptr < base_address + heap_size);

    // Scan for consistency between flags and size values
    void **next_valid = static_cast<void**>(base_address) + 1;
    void **cur = static_cast<void**>(base_address);
    for (cur = static_cast<void**>(base_address);
         cur < (void**)wilderness_ptr;
         cur++)
    {
        if (cur == next_valid) {
            unsigned size;
            assert(*cell_bits(cur) & GC_BITS_VALID);
            size = *cell_size(cur);
            assert(size > 0);
            next_valid = cur + size + 1;
        } else {
            assert(*cell_bits(cur) == 0);
        }
    }

    // Check the free list for consistency.
    cur = free_list;
    while (cur) {
        assert(*cell_bits(cur) == GC_BITS_VALID);
        // TODO check to avoid duplicates
        // TODO check to avoid free cells not on the free list.
        cur = static_cast<void**>(*cur);
    }
}
#endif

} // namespace pz

