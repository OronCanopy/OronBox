(component
  (type $ui (instance
    (export "render-to-text-card" (func (param "id" string) (param "text" string)))
  ))
  (import "astrobox:psys-host-v4/ui" (instance $ui (type $ui)))
  (alias export $ui "render-to-text-card" (func $render))
  (core module $memory
    (memory (export "memory") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) (i32.const 4096))
    (data (i32.const 0) "Plugin UI")
  )
  (core instance $memory (instantiate $memory))
  (core func $render (canon lower (func $render) (memory (core memory $memory "memory"))))
  (core module $guest
    (import "" "render" (func $render (param i32 i32 i32 i32)))
    (func (export "render") (param $id i32) (param $len i32)
      (if (local.get $len)
        (then (call $render (local.get $id) (local.get $len) (i32.const 0) (i32.const 9)))))
  )
  (core instance $guest (instantiate $guest
    (with "" (instance (export "render" (func $render))))))
  (func (export "on-ui-render") (param "id" string)
    (canon lift (core func $guest "render")
      (memory (core memory $memory "memory"))
      (realloc (core func $memory "realloc"))))
)
