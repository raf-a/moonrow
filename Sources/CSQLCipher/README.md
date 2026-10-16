# SQLCipher

SQLCipher 4.19.0 (SQLite 3.53.4), the community edition from
https://github.com/sqlcipher/sqlcipher, as its amalgamation. BSD licence: `LICENSE.md`; SQLite
itself is in the public domain.

Made from the `v4.19.0` tag with:

    ./configure --with-tempstore=yes CFLAGS="-DSQLITE_HAS_CODEC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -DSQLCIPHER_CRYPTO_CC"
    make sqlite3.c

`sqlite3.c` and `sqlite3.h` are copied as they come out; the build settings are in
`Package.swift` (CommonCrypto from Security.framework as the crypto provider).
