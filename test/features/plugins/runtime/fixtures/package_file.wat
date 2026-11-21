;; wasm-tools parse package_file.wat -o package_file.wasm
(component
  (type $filesystem (instance
    (export "descriptor" (type $descriptor (sub resource)))
    (type $error (enum "access" "would-block" "already" "bad-descriptor"
      "busy" "deadlock" "quota" "exist" "file-too-large" "illegal-byte-sequence"
      "in-progress" "interrupted" "invalid" "io" "is-directory" "loop"
      "too-many-links" "message-size" "name-too-long" "no-device" "no-entry"
      "no-lock" "insufficient-memory" "insufficient-space" "not-directory"
      "not-empty" "not-recoverable" "unsupported" "no-tty" "no-such-device"
      "overflow" "not-permitted" "pipe" "read-only" "invalid-seek"
      "text-file-busy" "cross-device"))
    (export "error-code" (type $export-error (eq $error)))
    (type $path-flags (flags "symlink-follow"))
    (export "path-flags" (type $export-path-flags (eq $path-flags)))
    (type $open-flags (flags "create" "directory" "exclusive" "truncate"))
    (export "open-flags" (type $export-open-flags (eq $open-flags)))
    (type $descriptor-flags (flags "read" "write" "file-integrity-sync"
      "data-integrity-sync" "requested-write-sync" "mutate-directory"))
    (export "descriptor-flags" (type $export-descriptor-flags (eq $descriptor-flags)))
    (export "[method]descriptor.open-at" (func
      (param "self" (borrow $descriptor))
      (param "path-flags" $export-path-flags) (param "path" string)
      (param "open-flags" $export-open-flags) (param "flags" $export-descriptor-flags)
      (result (result (own $descriptor) (error $export-error)))))
    (export "[method]descriptor.read" (func
      (param "self" (borrow $descriptor)) (param "length" u64) (param "offset" u64)
      (result (result (tuple (list u8) bool) (error $export-error)))))
  ))
  (import "wasi:filesystem/types@0.2.0" (instance $fs (type $filesystem)))
  (alias export $fs "descriptor" (type $descriptor))
  (type $preopens (instance
    (alias outer 1 $descriptor (type $descriptor))
    (export "descriptor" (type $directory (eq $descriptor)))
    (export "get-directories" (func (result (list (tuple (own $directory) string)))))
  ))
  (import "wasi:filesystem/preopens@0.2.0" (instance $preopens (type $preopens)))
  (core module $memory
    (memory (export "memory") 1)
    (global $heap (mut i32) (i32.const 1024))
    (func (export "realloc") (param i32 i32) (param $align i32) (param $size i32) (result i32)
      (local $ptr i32)
      (local.set $ptr (i32.and
        (i32.add (global.get $heap) (i32.sub (local.get $align) (i32.const 1)))
        (i32.sub (i32.const 0) (local.get $align))))
      (global.set $heap (i32.add (local.get $ptr) (local.get $size)))
      (local.get $ptr))
    (data (i32.const 64) "missing")
  )
  (core instance $memory (instantiate $memory))
  (alias export $fs "[method]descriptor.open-at" (func $open))
  (alias export $fs "[method]descriptor.read" (func $read))
  (alias export $preopens "get-directories" (func $directories))
  (core func $open (canon lower (func $open)
    (memory (core memory $memory "memory")) (realloc (core func $memory "realloc"))))
  (core func $read (canon lower (func $read)
    (memory (core memory $memory "memory")) (realloc (core func $memory "realloc"))))
  (core func $directories (canon lower (func $directories)
    (memory (core memory $memory "memory")) (realloc (core func $memory "realloc"))))
  (core func $drop (canon resource.drop $descriptor))
  (core module $guest
    (import "" "memory" (memory 1))
    (import "" "open" (func $open (param i32 i32 i32 i32 i32 i32 i32)))
    (import "" "read" (func $read (param i32 i64 i64 i32)))
    (import "" "directories" (func $directories (param i32)))
    (import "" "drop" (func $drop (param i32)))
    (func (export "read-file") (param $path i32) (param $length i32) (result i32)
      (local $entry i32) (local $end i32) (local $cwd i32) (local $file i32)
      (call $directories (i32.const 0))
      (local.set $entry (i32.load (i32.const 0)))
      (local.set $end (i32.add (local.get $entry) (i32.mul (i32.load (i32.const 4)) (i32.const 12))))
      (i32.store (i32.const 48) (i32.const 64))
      (i32.store (i32.const 52) (i32.const 7))
      (block $done
        (loop $next
          (br_if $done (i32.ge_u (local.get $entry) (local.get $end)))
          (local.set $cwd (i32.load (local.get $entry)))
          (if (i32.and (i32.eq (i32.load offset=8 (local.get $entry)) (i32.const 1))
                (i32.eq (i32.load8_u (i32.load offset=4 (local.get $entry))) (i32.const 46)))
            (then
              (call $open (local.get $cwd) (i32.const 0) (local.get $path) (local.get $length)
                (i32.const 0) (i32.const 1) (i32.const 8))
              (if (i32.eqz (i32.load8_u (i32.const 8)))
                (then
                  (local.set $file (i32.load (i32.const 12)))
                  (call $read (local.get $file) (i64.const 4096) (i64.const 0) (i32.const 16))
                  (call $drop (local.get $file))
                  (if (i32.eqz (i32.load8_u (i32.const 16)))
                    (then
                      (i32.store (i32.const 48) (i32.load (i32.const 20)))
                      (i32.store (i32.const 52) (i32.load (i32.const 24)))))))))
          (call $drop (local.get $cwd))
          (local.set $entry (i32.add (local.get $entry) (i32.const 12)))
          (br $next)))
      (i32.const 48))
  )
  (core instance $guest (instantiate $guest (with "" (instance
    (export "memory" (memory $memory "memory")) (export "open" (func $open))
    (export "read" (func $read)) (export "directories" (func $directories))
    (export "drop" (func $drop))))))
  (func (export "on-ui-render") (param "path" string) (result string)
    (canon lift (core func $guest "read-file")
      (memory (core memory $memory "memory")) (realloc (core func $memory "realloc"))))
)
