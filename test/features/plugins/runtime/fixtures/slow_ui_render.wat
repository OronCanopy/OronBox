(component
  (type $clock (instance (export "now" (func (result u64)))))
  (import "wasi:clocks/monotonic-clock@0.2.6" (instance $clock (type $clock)))
  (alias export $clock "now" (func $now))
  (core func $now (canon lower (func $now)))
  (core module $guest
    (import "" "now" (func $now (result i64)))
    (memory (export "memory") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 4096))
    (func (export "render") (param i32 i32) (local $start i64)
      (local.set $start (call $now))
      (loop $wait
        (br_if $wait (i64.lt_u (i64.sub (call $now) (local.get $start)) (i64.const 250000000)))))
  )
  (core instance $guest (instantiate $guest (with "" (instance (export "now" (func $now))))))
  (func (export "on-ui-render") (param "id" string)
    (canon lift (core func $guest "render") (memory (core memory $guest "memory")) (realloc (core func $guest "realloc"))))
)
