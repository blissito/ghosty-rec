# ghosty-rec

Graba **una sola ventana** de macOS desde la terminal, aunque otra la tape, y la convierte en un
video estilo Screen Studio con zooms dirigidos por lo que el agente dice que está haciendo.

```sh
rec windows --json                                    # id, app, título, rect
rec start --id 651 --out demo.mov                     # graba en segundo plano
rec mark "aprieta Merge" --rect 0,40,300,60 --say "Un clic y queda mergeado"
rec stop
rec render demo.mov --aspect 9:16 --no-titlebar       # zoom, cursor, fondo, pastilla
```

- Nunca graba la pantalla completa.
- Salida en JSON para agentes. Código de salida 3 si falta el permiso de Grabación de pantalla.
- `render` deja `demo.project.json`. Cada zoom lleva `"enabled"`: si lo pones en `false`,
  ese zoom desaparece al volver a renderizar.
- Tope de nitidez: no estira lo grabado más de 1.5× (`--max-upscale`). Graba con letra grande o en Retina.

macOS 15+. `swift build -c release`.

Las curvas del zoom y del cursor siguen los valores de [OpenScreen](https://github.com/siddharthvaddem/openscreen) (MIT).
