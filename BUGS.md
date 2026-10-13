# Tin compiler bugs

- `tests/compiler_bugs/forward_map_struct_key.tin`: Tin segfaults when a struct declares a map whose struct key and struct value types are declared later in the package. The transaction manager avoids the compiler bug by declaring `LockMode`, `LockKey` and `LockHolder` before `Manager`.
