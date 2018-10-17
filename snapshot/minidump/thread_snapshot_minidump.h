// Copyright 2018 The Crashpad Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef CRASHPAD_SNAPSHOT_MINIDUMP_THREAD_SNAPSHOT_MINIDUMP_H_
#define CRASHPAD_SNAPSHOT_MINIDUMP_THREAD_SNAPSHOT_MINIDUMP_H_

#include <windows.h>

#include "minidump/minidump_extensions.h"
#include "snapshot/thread_snapshot.h"
#include "util/file/file_reader.h"
#include "util/misc/initialization_state_dcheck.h"

namespace crashpad {
namespace internal {

//! \brief A ThreadSnapshot based on a thread in a minidump file.
class ThreadSnapshotMinidump : public ThreadSnapshot {
 public:
  ThreadSnapshotMinidump();
  ~ThreadSnapshotMinidump() override;

  //! \brief Initializes the object.
  //!
  //! \param[in] file_reader A file reader corresponding to a minidump file.
  //!     The file reader must support seeking.
  //! \param[in] minidump_thread_rva The file offset in \a file_reader at which
  //!     the thread’s MINIDUMP_THREAD structure is located.
  //!
  //! \return `true` if the snapshot could be created, `false` otherwise with
  //!     an appropriate message logged.
  bool Initialize(FileReaderInterface* file_reader, RVA minidump_thread_rva);

  const CPUContext* Context() const override;
  const MemorySnapshot* Stack() const override;
  uint64_t ThreadID() const override;
  int SuspendCount() const override;
  int Priority() const override;
  uint64_t ThreadSpecificDataAddress() const override;
  std::vector<const MemorySnapshot*> ExtraMemory() const override;

 private:
  MINIDUMP_THREAD minidump_thread_;
  InitializationStateDcheck initialized_;
};

}  // namespace internal
}  // namespace crashpad

#endif  // CRASHPAD_SNAPSHOT_MINIDUMP_THREAD_SNAPSHOT_MINIDUMP_H_
