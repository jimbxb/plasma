/*
 * Plasma bytecode reader
 * vim: ts=4 sw=4 et
 *
 * Copyright (C) 2015-2916, 2020-2021 Plasma Team
 * Distributed under the terms of the MIT license, see ../LICENSE.code
 */

#ifndef PZ_READ_H
#define PZ_READ_H

namespace pz {

/*
 * Read a bytecode library from the given file.  it may reference symbols in
 * pz.  library and names are out-parameters, names is ignored if it's null.
 */
bool read(PZ & pz, const std::string & filename, Root<Library> & library,
          Vector<String> * names, GCTracer & gc);

}  // namespace pz

#endif /* ! PZ_READ_H */
