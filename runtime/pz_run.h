/*
 * Plasma bytecode exection
 * vim: ts=4 sw=4 et
 *
 * Copyright (C) 2015 Paul Bone
 * Distributed under the terms of the MIT license, see ../LICENSE.runtime
 */

#ifndef PZ_RUN_H
#define PZ_RUN_H

#include "pz_instructions.h"
#include "pz.h"

typedef union stack_value {
    uint8_t     u8;
    uint16_t    u16;
    uint32_t    u32;
    uint64_t    u64;
    uintptr_t   uptr;
} stack_value;

typedef unsigned (*ccall_func)(stack_value*, unsigned);

unsigned
builtin_print(stack_value* stack, unsigned sp);

/*
 * Run the program.
 */
int
pz_run(struct pz*);

/*
 * Get the in-memory size of the immediate value.
 */
unsigned
pz_immediate_size(enum immediate_type imm);

/*
 * Return the size of the given instruction, exlucing any immediate value.
 */
unsigned
pz_instr_size(opcode opcode);

/*
 * Write the instruction into the procedure at the given offset.
 */
void
pz_write_instr(uint8_t* proc, unsigned offset, opcode opcode);

/*
 * Write the immediate value (of various sizes) into the procedure at the
 * given offset.
 */
void
pz_write_imm8(uint8_t* proc, unsigned offset, uint8_t val);

void
pz_write_imm16(uint8_t* proc, unsigned offset, uint16_t val);

void
pz_write_imm32(uint8_t* proc, unsigned offset, uint32_t val);

void
pz_write_imm64(uint8_t* proc, unsigned offset, uint64_t val);

/*
 * TODO: Handle relative addressing and maybe PIC.
 */
void
pz_write_imm_word(uint8_t* proc, unsigned offset, uintptr_t val);

#endif /* ! PZ_RUN_H */
