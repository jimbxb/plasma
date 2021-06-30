/*
 * Plasma bytecode reader
 * vim: ts=4 sw=4 et
 *
 * Copyright (C) 2015-2021 Plasma Team
 * Distributed under the terms of the MIT license, see ../LICENSE.code
 */

#include <errno.h>
#include <string.h>

#include "pz_common.h"

#include "pz.h"
#include "pz_closure.h"
#include "pz_code.h"
#include "pz_data.h"
#include "pz_format.h"
#include "pz_interp.h"
#include "pz_io.h"
#include "pz_read.h"
#include "pz_string.h"

namespace pz {

struct Imported {
    Imported(unsigned num_imports) : num_imports_(num_imports)
    {
        import_closures.reserve(num_imports);
        imports.reserve(num_imports);
    }

    unsigned               num_imports_;
    std::vector<Closure *> import_closures;
    std::vector<unsigned>  imports;
};

struct ReadInfo {
    PZ &        pz;
    BinaryInput file;
    bool        verbose;
    bool        load_debuginfo;

    ReadInfo(PZ & pz_)
        : pz(pz_)
        , verbose(pz.options().verbose())
        , load_debuginfo(pz.options().interp_trace())
    {}

    Heap * heap() const
    {
        return pz.heap();
    }
};

/*
 * The closure id and signature type for the program's entrypoint
 */
struct EntryClosure {
    PZOptEntrySignature signature;
    uint32_t            closure_id;

    EntryClosure(PZOptEntrySignature sig, uint32_t clo)
        : signature(sig)
        , closure_id(clo)
    {}
};

static bool
read_options(BinaryInput &file, Optional<EntryClosure> &entry_closure);

static bool
read_imports(ReadInfo    &read,
             unsigned     num_imports,
             Imported    &imported);

static bool
read_structs(ReadInfo       &read,
             unsigned        num_structs,
             LibraryLoading &library);

static bool
read_data(ReadInfo       &read,
          unsigned        num_datas,
          LibraryLoading &library,
          Imported       &imports);

static Optional<PZ_Width>
read_data_width(BinaryInput &file);

static bool
read_data_slot(ReadInfo       &read,
               void           *dest,
               LibraryLoading &library,
               Imported       &imports);

static bool
read_code(ReadInfo       &read,
          unsigned        num_procs,
          LibraryLoading &library,
          Imported       &imported);

static unsigned
read_proc(ReadInfo       &read,
          Imported       &imported,
          LibraryLoading &library,
          Proc           *proc, /* null fir first pass */
          unsigned      **block_offsets);

static bool
read_instr(BinaryInput      &file,
           Imported         &imported,
           LibraryLoading   &library,
           uint8_t          *proc_code,
           unsigned        **block_offsets,
           unsigned         &proc_offset);

static bool
read_meta(ReadInfo          &read,
          LibraryLoading    &library,
          Proc              *proc,
          unsigned           proc_offset,
          uint8_t            meta_byte);

static bool
read_closures(ReadInfo       &read,
              unsigned        num_closures,
              Imported       &imported,
              LibraryLoading &library);

static bool
read_exports(ReadInfo       &read,
             unsigned        num_exports,
             LibraryLoading &library);

bool
read(PZ &pz, const std::string &filename, Library **library,
        std::vector<std::string> &names)
{
    ReadInfo read(pz);
    uint32_t magic;
    uint16_t version;
    uint32_t num_imports;
    uint32_t num_structs;
    uint32_t num_datas;
    uint32_t num_procs;
    uint32_t num_closures;
    uint32_t num_exports;

    if (!read.file.open(filename)) {
        perror(filename.c_str());
        return false;
    }

    if (!read.file.read_uint32(&magic)) return false;
    switch (magic) {
        case PZ_OBJECT_MAGIC_NUMBER:
            fprintf(stderr,
                    "%s: Cannot execute plasma objects, "
                    "link objects into a program first.\n",
                    filename.c_str());
            return false;
        case PZ_PROGRAM_MAGIC_NUMBER:
        case PZ_LIBRARY_MAGIC_NUMBER:
            break;  // good, we continue
        default:
            fprintf(stderr,
                    "%s: bad magic value, is this a PZ file?\n",
                    filename.c_str());
            return false;
    }

    {
        Optional<std::string> string = read.file.read_len_string();
        if (!string.hasValue()) return false;
        if (!startsWith(string.value(), PZ_PROGRAM_MAGIC_STRING) &&
            !startsWith(string.value(), PZ_LIBRARY_MAGIC_STRING))
        {
            fprintf(stderr,
                    "%s: bad version string, is this a PZ file?\n",
                    filename.c_str());
            return false;
        }
    }

    if (!read.file.read_uint16(&version)) return false;
    if (version != PZ_FORMAT_VERSION) {
        fprintf(stderr,
                "Incorrect PZ version, found %d, expecting %d\n",
                version,
                PZ_FORMAT_VERSION);
        return false;
    }

    Optional<EntryClosure> entry_closure;
    if (!read_options(read.file, entry_closure)) return false;

    uint32_t num_names;
    if (!read.file.read_uint32(&num_names)) return false;
    for (unsigned i = 0; i < num_names; i++) {
        Optional<std::string> name = read.file.read_len_string();
        if (!name.hasValue()) return false;
        names.push_back(name.value());
    }

    if (!read.file.read_uint32(&num_imports)) return false;
    if (!read.file.read_uint32(&num_structs)) return false;
    if (!read.file.read_uint32(&num_datas)) return false;
    if (!read.file.read_uint32(&num_procs)) return false;
    if (!read.file.read_uint32(&num_closures)) return false;
    if (!read.file.read_uint32(&num_exports)) return false;

    std::unique_ptr<LibraryLoading> lib_load;
    {
        NoRootsTracer no_roots(read.heap());
        NoGCScope     no_gc(&no_roots);

        lib_load =
            std::unique_ptr<LibraryLoading>(new LibraryLoading(num_structs,
                                                               num_datas,
                                                               num_procs,
                                                               num_closures,
                                                               no_gc));

        no_gc.abort_if_oom("loading a module");
    }

    Imported imported(num_imports);

    if (!read_imports(read, num_imports, imported)) return false;

    if (!read_structs(read, num_structs, *lib_load)) return false;

    /*
     * read the file in two passes.  During the first pass we calculate the
     * sizes of datas and procedures and therefore calculating the addresses
     * where each individual entry begins.  Then in the second pass we fill
     * read the bytecode and data, resolving any intra-module references.
     */
    if (!read_data(read, num_datas, *lib_load, imported)) {
        return false;
    }
    if (!read_code(read, num_procs, *lib_load, imported)) {
        return false;
    }

    if (!read_closures(read, num_closures, imported, *lib_load)) {
        return false;
    }

    if (!read_exports(read, num_exports, *lib_load)) {
        return false;
    }

#ifdef PZ_DEV
    /*
     * We should now be at the end of the file, so we should expect to get
     * an error if we read any further.
     */
    uint8_t extra_byte;
    if (read.file.read_uint8(&extra_byte)) {
        fprintf(stderr, "%s: junk at end of file\n", filename.c_str());
        return false;
    }
    if (!read.file.is_at_eof()) {
        fprintf(stderr, "%s: junk at end of file\n", filename.c_str());
        return false;
    }
#endif
    read.file.close();

    // If we were to GC here we would fail to trace all the objects we've
    // just read as they're not yet reachable.
    // XXX: This scope really ought to last until after our caller has
    // stored the returned pointer.
    NoGCScope nogc(&read.pz);
    *library = new (nogc) Library(*lib_load);
    if (entry_closure.hasValue()) {
        (*library)->set_entry_closure(entry_closure.value().signature,
                lib_load->closure(entry_closure.value().closure_id));
    }
    if (nogc.is_oom()) {
        fprintf(stderr, "OOM during module reading\n");
        return false;
    }

    return true;
}

static bool read_options(BinaryInput & file, Optional<EntryClosure> & mbEntry)
{
    uint16_t num_options;

    if (!file.read_uint16(&num_options)) return false;

    for (unsigned i = 0; i < num_options; i++) {
        uint16_t type, len;

        if (!file.read_uint16(&type)) return false;
        if (!file.read_uint16(&len)) return false;

        switch (type) {
            case PZ_OPT_ENTRY_CLOSURE: {
                uint8_t  entry_signature_uint;
                uint32_t entry_closure;
                if (len != 5) {
                    fprintf(stderr,
                            "%s: Corrupt file while reading options",
                            file.filename_c());
                    return false;
                }
                if (!file.read_uint8(&entry_signature_uint)) return false;
                if (!file.read_uint32(&entry_closure)) return false;

                PZOptEntrySignature entry_signature =
                    static_cast<PZOptEntrySignature>(entry_signature_uint);
                mbEntry.set(EntryClosure(entry_signature, entry_closure));
                break;
            }
            default:
                if (!file.seek_cur(len)) return false;
                break;
        }
    }

    return true;
}

static bool read_imports(ReadInfo & read, unsigned num_imports,
                         Imported & imported)
{
    for (uint32_t i = 0; i < num_imports; i++) {
        Optional<std::string> maybe_module_name = read.file.read_len_string();
        if (!maybe_module_name.hasValue()) return false;
        std::string           module_name = maybe_module_name.value();
        Optional<std::string> maybe_name  = read.file.read_len_string();
        if (!maybe_name.hasValue()) return false;
        std::string name = maybe_name.value();

        Library * library = read.pz.lookup_library(module_name);
        if (!library) {
            fprintf(stderr, "Module not found: %s\n", module_name.c_str());
            return false;
        }

        Optional<Export> maybe_export =
            library->lookup_symbol(module_name + "." + name);
        if (maybe_export.hasValue()) {
            Export export_ = maybe_export.value();
            imported.imports.push_back(export_.id());
            imported.import_closures.push_back(export_.closure());
        } else {
            fprintf(stderr,
                    "Procedure not found: %s.%s\n",
                    module_name.c_str(),
                    name.c_str());
            return false;
        }
    }

    return true;
}

static bool
read_structs(ReadInfo       &read,
             unsigned        num_structs,
             LibraryLoading &library)
{
    for (unsigned i = 0; i < num_structs; i++) {
        uint32_t num_fields;

        if (!read.file.read_uint32(&num_fields)) return false;

        Struct * s = library.new_struct(num_fields, library);

        for (unsigned j = 0; j < num_fields; j++) {
            Optional<PZ_Width> mb_width = read_data_width(read.file);
            if (mb_width.hasValue()) {
                s->set_field(j, mb_width.value());
            } else {
                return false;
            }
        }

        s->calculate_layout();
    }

    return true;
}

static bool
read_data(ReadInfo       &read,
          unsigned        num_datas,
          LibraryLoading &library,
          Imported       &imports)
{
    unsigned total_size = 0;
    void *   data       = nullptr;

    for (uint32_t i = 0; i < num_datas; i++) {
        uint8_t data_type_id;

        if (!read.file.read_uint8(&data_type_id)) return false;
        switch (data_type_id) {
            case PZ_DATA_ARRAY: {
                uint16_t  num_elements;
                uint8_t * data_ptr;
                if (!read.file.read_uint16(&num_elements)) return false;
                Optional<PZ_Width> maybe_width = read_data_width(read.file);
                if (!maybe_width.hasValue()) return false;
                PZ_Width width = maybe_width.value();
                data     = data_new_array_data(library, width, num_elements);
                data_ptr = (uint8_t *)data;
                for (unsigned i = 0; i < num_elements; i++) {
                    if (!read_data_slot(read, data_ptr, library, imports)) {
                        return false;
                    }
                    data_ptr += width_to_bytes(width);
                }
                total_size += width_to_bytes(width) * num_elements;
                break;
            }
            case PZ_DATA_STRUCT: {
                uint32_t struct_id;
                if (!read.file.read_uint32(&struct_id)) return false;
                const Struct * struct_ = library.struct_(struct_id);

                data = data_new_struct_data(library, struct_->total_size());
                for (unsigned f = 0; f < struct_->num_fields(); f++) {
                    void * dest = reinterpret_cast<uint8_t *>(data) +
                                  struct_->field_offset(f);
                    if (!read_data_slot(read, dest, library, imports)) {
                        return false;
                    }
                }
                break;
            }
            case PZ_DATA_STRING: {
                uint16_t  num_elements;
                if (!read.file.read_uint16(&num_elements)) return false;
                
                uint8_t * data_ptr;
                FlatString *s = FlatString::New(library, num_elements);
                data = String(s).ptr();
                // TODO: utf8
                data_ptr = s->buffer();
                for (unsigned i = 0; i < num_elements; i++) {
                    if (!read_data_slot(read, data_ptr, library, imports)) {
                        return false;
                    }
                    data_ptr++;
                }
                total_size += s->storageSize();
                break;
            }
        }

        library.add_data(data);
        data = nullptr;
    }

    if (read.verbose) {
        printf("Loaded %d data entries with a total of %d bytes\n",
               (unsigned)num_datas,
               total_size);
    }

    return true;
}

static Optional<PZ_Width> read_data_width(BinaryInput & file)
{
    uint8_t raw_width;
    if (!file.read_uint8(&raw_width)) return Optional<PZ_Width>::Nothing();
    return width_from_int(raw_width);
}

static bool
read_data_slot(ReadInfo       &read,
               void           *dest,
               LibraryLoading &library,
               Imported       &imports)
{
    uint8_t               enc_width, raw_enc;
    enum pz_data_enc_type type;

    if (!read.file.read_uint8(&raw_enc)) return false;
    type = PZ_DATA_ENC_TYPE(raw_enc);

    switch (type) {
        case pz_data_enc_type_normal:
            enc_width = PZ_DATA_ENC_BYTES(raw_enc);
            switch (enc_width) {
                case 1: {
                    uint8_t value;
                    if (!read.file.read_uint8(&value)) return false;
                    data_write_normal_uint8(dest, value);
                    return true;
                }
                case 2: {
                    uint16_t value;
                    if (!read.file.read_uint16(&value)) return false;
                    data_write_normal_uint16(dest, value);
                    return true;
                }
                case 4: {
                    uint32_t value;
                    if (!read.file.read_uint32(&value)) return false;
                    data_write_normal_uint32(dest, value);
                    return true;
                }
                case 8: {
                    uint64_t value;
                    if (!read.file.read_uint64(&value)) return false;
                    data_write_normal_uint64(dest, value);
                    return true;
                }
                default:
                    fprintf(stderr, "Unexpected data encoding %d.\n", raw_enc);
                    return false;
            }
        case pz_data_enc_type_fast: {
            uint32_t i32;

            /*
             * For these width types the encoded width is 32bit.
             */
            if (!read.file.read_uint32(&i32)) return false;
            data_write_fast_from_int32(dest, i32);
            return true;
        }
        case pz_data_enc_type_wptr: {
            int32_t i32;

            /*
             * For these width types the encoded width is 32bit.
             */
            if (!read.file.read_uint32((uint32_t *)&i32)) return false;
            data_write_wptr(dest, (uintptr_t)i32);
            return true;
        }
        case pz_data_enc_type_data: {
            uint32_t ref;
            void **  dest_ = (void **)dest;
            void *   data;

            // Data is a reference, link in the correct information.
            // XXX: support non-data references, such as proc
            // references.
            if (!read.file.read_uint32(&ref)) return false;
            data = library.data(ref);
            if (data != nullptr) {
                *dest_ = data;
            } else {
                fprintf(stderr, "forward references arn't yet supported.\n");
                abort();
            }
            return true;
        }
        case pz_data_enc_type_import: {
            uint32_t  ref;
            void **   dest_ = (void **)dest;
            Closure * import;

            // Data is a reference, link in the correct information.
            // XXX: support non-data references, such as proc
            // references.
            if (!read.file.read_uint32(&ref)) return false;
            assert(ref < imports.num_imports_);
            import = imports.import_closures[ref];
            assert(import);
            *dest_ = import;
            return true;
        }
        case pz_data_enc_type_closure: {
            uint32_t ref;
            void **  dest_ = (void **)dest;

            if (!read.file.read_uint32(&ref)) return false;
            Closure * closure = library.closure(ref);
            assert(closure);
            *dest_ = closure;
            return true;
        }
        default:
            // GCC is having trouble recognising this complete switch.
            fprintf(stderr, "Unrecognised data item encoding.\n");
            abort();
    }
}

static bool
read_code(ReadInfo       &read,
          unsigned        num_procs,
          LibraryLoading &library,
          Imported       &imported)
{
    bool        result        = false;
    unsigned ** block_offsets = new unsigned *[num_procs];

    memset(block_offsets, 0, sizeof(unsigned *) * num_procs);

    /*
     * We read procedures in two phases, once to calculate their sizes, and
     * label offsets, allocating memory for each one.  Then the we read them
     * for real in the second phase when memory locations are known.
     */
    if (read.verbose) {
        fprintf(stderr, "Reading procs first pass\n");
    }
    auto file_pos = read.file.tell();
    if (!file_pos.hasValue()) goto end;

    for (unsigned i = 0; i < num_procs; i++) {
        unsigned proc_size;

        if (read.verbose) {
            fprintf(stderr, "Reading proc %d\n", i);
        }

        proc_size =
            read_proc(read, imported, library, nullptr, &block_offsets[i]);
        if (proc_size == 0) goto end;
        library.new_proc(proc_size, false, library);
    }

    /*
     * Now that we've allocated memory for all the procedures, re-read them
     * this time writing them into that memory.  We do this for all the
     * procedures at once otherwise calls in earlier procedures would not
     * know the code addresses of later procedures.
     */
    if (read.verbose) {
        fprintf(stderr, "Beginning second pass\n");
    }
    if (!read.file.seek_set(file_pos.value())) goto end;
    for (unsigned i = 0; i < num_procs; i++) {
        if (read.verbose) {
            fprintf(stderr, "Reading proc %d\n", i);
        }

        if (0 ==
            read_proc(
                read, imported, library, library.proc(i), &block_offsets[i])) {
            goto end;
        }
    }

    if (read.verbose) {
        library.print_loaded_stats();
    }
    result = true;

end:
    if (block_offsets != nullptr) {
        for (unsigned i = 0; i < num_procs; i++) {
            if (block_offsets[i] != nullptr) {
                delete[] block_offsets[i];
            }
        }
        delete[] block_offsets;
    }
    return result;
}

static unsigned
read_proc(ReadInfo       &read,
          Imported       &imported,
          LibraryLoading &library,
          Proc           *proc,
          unsigned      **block_offsets)
{
    uint32_t      num_blocks;
    bool          first_pass  = (proc == nullptr);
    unsigned      proc_offset = 0;
    BinaryInput & file        = read.file;

    Optional<String> name = file.read_len_string(library);
    if (proc && name.hasValue()) {
        proc->set_name(name.value());
    }

    /*
     * XXX: Signatures currently aren't written into the bytecode, but
     * here's where they might appear.
     */

    if (!file.read_uint32(&num_blocks)) return 0;
    if (first_pass) {
        /*
         * This is the first pass - set up the block offsets array.
         */
        *block_offsets = new unsigned[num_blocks];
    }

    for (unsigned i = 0; i < num_blocks; i++) {
        uint32_t num_instructions;

        if (first_pass) {
            /*
             * Fill in the block_offsets array
             */
            (*block_offsets)[i] = proc_offset;
        }

        if (!file.read_uint32(&num_instructions)) return 0;
        for (uint32_t j = 0; j < num_instructions; j++) {
            uint8_t byte;
            if (!file.read_uint8(&byte)) return false;

            if (PZ_CODE_INSTR == byte) {
                if (!read_instr(file,
                                imported,
                                library,
                                proc ? proc->code() : nullptr,
                                block_offsets,
                                proc_offset))
                {
                    return 0;
                }
            } else {
                if (!read_meta(read, library, proc, proc_offset, byte)) {
                    return 0;
                }
            }
        }
    }

    return proc_offset;
}

static bool
read_instr(BinaryInput &file, Imported &imported, LibraryLoading &library,
        uint8_t *proc_code, unsigned **block_offsets, unsigned &proc_offset)
{
    uint8_t            byte;
    PZ_Opcode          opcode;
    Optional<PZ_Width> width1, width2;
    ImmediateType      immediate_type;
    ImmediateValue     immediate_value;
    bool               first_pass = (proc_code == nullptr);

    /*
     * Read the opcode and the data width(s)
     */
    if (!file.read_uint8(&byte)) return false;
    opcode = static_cast<PZ_Opcode>(byte);
    if (instruction_info[opcode].ii_num_width_bytes > 0) {
        width1 = read_data_width(file);
        if (instruction_info[opcode].ii_num_width_bytes > 1) {
            width2 = read_data_width(file);
        }
    }

    /*
     * Read any immediate value
     */
    immediate_type = instruction_info[opcode].ii_immediate_type;
    switch (immediate_type) {
        case IMT_NONE:
            memset(&immediate_value, 0, sizeof(ImmediateValue));
            break;
        case IMT_8:
            if (!file.read_uint8(&immediate_value.uint8)) return false;
            break;
        case IMT_16:
            if (!file.read_uint16(&immediate_value.uint16)) return false;
            break;
        case IMT_32:
            if (!file.read_uint32(&immediate_value.uint32)) return false;
            break;
        case IMT_64:
            if (!file.read_uint64(&immediate_value.uint64)) return false;
            break;
        case IMT_CLOSURE_REF: {
            uint32_t closure_id;
            if (!file.read_uint32(&closure_id)) return false;
            if (!first_pass) {
                immediate_value.word = (uintptr_t)library.closure(closure_id);
            } else {
                immediate_value.word = 0;
            }
            break;
        }
        case IMT_PROC_REF: {
            uint32_t proc_id;
            if (!file.read_uint32(&proc_id)) return false;
            if (!first_pass) {
                immediate_value.word = (uintptr_t)library.proc(proc_id)->code();
            } else {
                immediate_value.word = 0;
            }
            break;
        }
        case IMT_IMPORT_REF: {
            uint32_t import_id;
            if (!file.read_uint32(&import_id)) return false;
            // TODO Should lookup the offset within the struct in
            // case there's non-pointer sized things in there.
            immediate_value.uint16 =
                imported.imports.at(import_id) * sizeof(void *);
            break;
        }
        case IMT_IMPORT_CLOSURE_REF: {
            uint32_t import_id;
            if (!file.read_uint32(&import_id)) return false;
            immediate_value.word =
                (uintptr_t)imported.import_closures.at(import_id);
            break;
        }
        case IMT_LABEL_REF: {
            uint32_t imm32;
            if (!file.read_uint32(&imm32)) return false;
            if (!first_pass) {
                immediate_value.word =
                    (uintptr_t)&proc_code[(*block_offsets)[imm32]];
            } else {
                immediate_value.word = 0;
            }
            break;
        }
        case IMT_STRUCT_REF: {
            uint32_t imm32;
            if (!file.read_uint32(&imm32)) return false;
            immediate_value.word = library.struct_(imm32)->total_size();
            break;
        }
        case IMT_STRUCT_REF_FIELD: {
            uint32_t imm32;
            uint8_t  imm8;

            if (!file.read_uint32(&imm32)) return false;
            if (!file.read_uint8(&imm8)) return false;
            immediate_value.uint16 = library.struct_(imm32)->field_offset(imm8);
            break;
        }
    }

    if (width1.hasValue()) {
        if (width2.hasValue()) {
            assert(immediate_type == IMT_NONE);
            proc_offset = write_instr(
                proc_code, proc_offset, opcode, width1.value(), width2.value());
        } else {
            if (immediate_type == IMT_NONE) {
                proc_offset =
                    write_instr(proc_code, proc_offset, opcode, width1.value());
            } else {
                proc_offset = write_instr(proc_code,
                                          proc_offset,
                                          opcode,
                                          width1.value(),
                                          immediate_type,
                                          immediate_value);
            }
        }
    } else {
        if (immediate_type == IMT_NONE) {
            proc_offset = write_instr(proc_code, proc_offset, opcode);
        } else {
            proc_offset = write_instr(proc_code,
                                      proc_offset,
                                      opcode,
                                      immediate_type,
                                      immediate_value);
        }
    }

    return true;
}

static bool read_meta(ReadInfo & read, LibraryLoading & library, Proc * proc,
                      unsigned proc_offset, uint8_t meta_byte)
{
    BinaryInput & file = read.file;
    uint32_t      data_id;
    uint32_t      line_no;

    switch (meta_byte) {
        case PZ_CODE_META_CONTEXT: {
            // We only need to read the context info when enabled
            // and during the second pass.
            if (proc && read.load_debuginfo) {
                if (!file.read_uint32(&data_id)) return false;
                String filename = String::from_ptr(library.data(data_id));
                if (!file.read_uint32(&line_no)) return false;

                proc->add_context(library, proc_offset, filename, line_no);
            } else {
                file.seek_cur(8);
            }
            break;
        }
        case PZ_CODE_META_CONTEXT_SHORT: {
            if (proc && read.load_debuginfo) {
                if (!file.read_uint32(&line_no)) return false;
                proc->add_context(library, proc_offset, line_no);
            } else {
                file.seek_cur(4);
            }
            break;
        }
        case PZ_CODE_META_CONTEXT_NIL:
            if (proc && read.load_debuginfo) {
                proc->no_context(library, proc_offset);
            }
            break;
        default:
            fprintf(stderr, "Unknown byte in instruction stream");
            abort();
    }

    return true;
}

static bool
read_closures(ReadInfo       &read,
              unsigned        num_closures,
              Imported       &imported,
              LibraryLoading &library)
{
    for (unsigned i = 0; i < num_closures; i++) {
        uint32_t  proc_id;
        uint32_t  data_id;
        uint8_t * proc_code;
        void *    data;

        if (!read.file.read_uint32(&proc_id)) return false;
        proc_code = library.proc(proc_id)->code();

        if (!read.file.read_uint32(&data_id)) return false;
        data = library.data(data_id);

        library.closure(i)->init(proc_code, data);
    }

    return true;
}

static bool
read_exports(ReadInfo       &read,
             unsigned        num_exports,
             LibraryLoading &library)
{
    for (unsigned i = 0; i < num_exports; i++) {
        Optional<std::string> mb_name = read.file.read_len_string();
        if (!mb_name.hasValue()) {
            return false;
        }

        uint32_t clo_id;
        if (!read.file.read_uint32(&clo_id)) {
            return false;
        }

        Closure * closure = library.closure(clo_id);
        if (!closure) {
            fprintf(stderr, "Closure ID unknown");
            return false;
        }

        library.add_symbol(mb_name.value(), closure);
    }

    return true;
}

}  // namespace pz
