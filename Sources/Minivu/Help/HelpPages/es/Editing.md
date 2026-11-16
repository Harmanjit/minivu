# Edición

La edición se hace en el visor. Tus cambios se guardan como una lista de pasos
y se muestran a medida que los haces, pero nada cambia en el disco hasta que
guardas.

## Abrir una herramienta

Elige una herramienta en el menú **Imagen**, o lleva el puntero al borde
izquierdo del visor y elige una en el panel. Los controles de la herramienta
ocupan el lugar del panel y permanecen abiertos mientras trabajas.

- **Aplicar** añade el cambio a la imagen, **Cancelar** lo descarta y
  **Restablecer** devuelve los controles a su posición inicial.
- En el panel, **Girar y voltear** y **Efectos de color** aplican cada botón
  al instante; **OK** los cierra.
- En las herramientas con las que dibujas o pintas, elegir otro comando
  aplica lo que has hecho hasta el momento, en lugar de descartarlo.

## Las herramientas

- **Girar a la izquierda**, **Girar a la derecha**, **Voltear
  horizontalmente**, **Voltear verticalmente**.
- **Redimensionar/remuestrear…** define un nuevo tamaño en píxeles o en
  porcentaje, manteniendo o no la proporción, con uno de 11 filtros de
  remuestreo, desde Caja y Bilineal hasta Lanczos 8.
- **Tamaño del lienzo…** amplía o reduce el lienzo alrededor de la imagen,
  en píxeles o en porcentaje. Elige dónde queda la imagen con el anclaje de
  3 × 3 y rellena el espacio nuevo con un color o déjalo transparente. Un
  lienzo más pequeño recorta la imagen.
- **Recortar…**: arrastra el rectángulo o sus tiradores. Elige Libre, la forma
  propia de la imagen, o 1:1, 4:3, 3:2, 16:9 o 5:4, en vertical u horizontal.
- **Enderezar…** gira la imagen hasta 45° en cualquier sentido y recorta las
  esquinas vacías.
- **Perspectiva…** endereza algo fotografiado en ángulo, como un documento o
  un edificio. Arrastra los cuatro tiradores de las esquinas hasta las
  esquinas de algo que debería ser rectangular, o haz clic en **Auto** para
  que lo busque. **Mostrar resultado** previsualiza la corrección.
- **Ajustar > Ajustes RAW…**, solo para archivos RAW de cámara: exposición,
  realce (contraste), recuperación de altas luces, balance de blancos y
  reducción de ruido, a partir de los ajustes de la propia cámara. minivu no
  puede guardar sobre un archivo RAW, así que guarda el resultado con
  **Guardar como…**.
- **Ajustar > Iluminación…**: brillo, contraste, gamma, sombras y altas luces.
- **Ajustar > Colores…**: tono, saturación, luminosidad, temperatura y matiz,
  y rojo, verde y azul por separado.
- **Ajustar > Curvas…** y **Niveles…** para un control preciso de los tonos.
- **Ajustar > Mejora automática** mejora el tono y el color con un clic. Si
  la foto no necesita nada, minivu emite un pitido.
- **Ajustar > Enfocar…**, **Desenfocar…** y **Reducción de ruido…**. La
  reducción de ruido suaviza el grano y conserva los bordes; su regulador
  Nitidez recupera el detalle.
- **Editar comentario…** define el comentario guardado en un archivo JPEG. Se
  escribe en el archivo al hacer clic en Guardar en el editor de comentarios.
- **Editar metadatos…** (**⌘I**) cambia la información del archivo. Consulta
  Metadatos más abajo.

Para efectos, dibujo y retoque, consulta
[Efectos y retoque](help:Effects).

## Metadatos

Los metadatos son la información guardada con una foto: quién la tomó,
cuándo, dónde, y un título o palabras clave. **Imagen > Editar metadatos…**
(**⌘I**) los edita para la imagen que se muestra, o para todas las imágenes
seleccionadas en el explorador.

- **Descripción:** título, pie de foto, creador y copyright.
- **Palabras clave:** añade palabras clave, separadas por comas, o quita una
  de todas las imágenes.
- **Fecha de captura:** desplaza la fecha en días, horas, minutos y segundos,
  o define una fecha y una hora nuevas.
- **Ubicación:** **Eliminar ubicación** quita la posición GPS y los nombres
  de lugar.

Con varias imágenes, un campo cuyo valor es distinto muestra “Mixto”. Déjalo
vacío para conservar el valor de cada archivo. Solo se escriben los campos
que cambies.

Los metadatos se escriben en el archivo sin volver a codificar la imagen. Los
archivos RAW de cámara, y los formatos que minivu no puede reescribir,
reciben en su lugar un archivo auxiliar XMP: un archivo pequeño con el mismo
nombre junto a la foto, que otras apps también leen.

## Deshacer

**Edición > Deshacer** y **Rehacer** retroceden y avanzan por tus ediciones,
hasta 50 pasos. Deshacer no consume memoria adicional, así que puedes
retroceder tantas veces como quieras. Después de guardar, el historial de
deshacer vuelve a empezar.

## Guardar

- **Archivo > Guardar** escribe la imagen editada sobre el original, en el
  mismo formato, espacio de color y profundidad de bits, con sus metadatos.
  minivu pregunta antes de reemplazar el original; si le indicaste que no
  volviera a preguntar, vuelve a activar **Preguntar antes de guardar sobre el
  original** en **Ajustes > General**.
- minivu no puede volver a escribir algunos formatos, como RAW, WebP, PDF y
  los archivos animados y multipágina. Con ellos, Guardar abre Guardar como.
- **Archivo > Guardar como…** guarda un archivo nuevo. Elige el formato (JPEG,
  PNG, HEIC, AVIF si tu Mac puede escribirlo, TIFF, BMP, GIF, TGA, JPEG 2000
  o ICO) y sus opciones: calidad, perfil de color, metadatos, progresivo, 16
  o 10 bits por canal, compresión TIFF y el fondo para la transparencia.
- **Eliminar ubicación**, bajo Conservar los metadatos, omite la posición GPS
  y los nombres de lugar en el archivo nuevo. Empieza activado. Guardar, y
  Guardar como sobre el archivo original, siempre conservan la ubicación. El
  panel muestra el tamaño de archivo que darán las opciones y puede abrir una
  comparación, una al lado de otra, del original y el resultado comprimido al
  100, 200 o 400 %. Las opciones se recuerdan para cada formato.
- **Archivo > Volver a la versión guardada** descarta tus ediciones sin
  guardar.
- **Archivo > Guardar ediciones como preajuste…** conserva las ediciones como
  un preajuste, para que **Herramientas > Convertir por lotes…** pueda
  aplicarlas a muchas imágenes. La hoja enumera los pasos que puede usar y
  los que omite, con el motivo. Consulta [Herramientas](help:Tools).
- Si pasas a otra imagen, vuelves al explorador o sales con ediciones sin
  guardar, minivu pregunta si quieres guardarlas antes.

> Si otra app modifica el archivo mientras tienes ediciones sin guardar,
> minivu pregunta si quieres conservar tus ediciones o volver a cargar el
> archivo. Si las conservas, Guardar pasa a ser Guardar como, así que no se
> pierde ninguna de las dos versiones.

Al guardar, las fotos JPEG, HEIC y AVIF con un mapa de ganancia (datos
adicionales que indican a una pantalla HDR cuánto brillo puede tener cada parte)
siguen siendo HDR. Las demás fotos HDR se guardan en rango dinámico estándar, y
minivu te lo avisa antes de guardar.
