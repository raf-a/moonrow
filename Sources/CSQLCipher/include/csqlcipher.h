// SQLCipher's declarations (sqlite3_key, sqlite3_rekey, …) are behind SQLITE_HAS_CODEC, which
// the C target defines for its own build; Swift sees the header through this one.
#ifndef SQLITE_HAS_CODEC
#define SQLITE_HAS_CODEC 1
#endif
#include "sqlite3.h"
