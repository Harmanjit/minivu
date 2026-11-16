# Herramientas

El menú **Herramientas** actúa sobre lo que estás viendo. En el explorador,
una herramienta usa las imágenes seleccionadas o, si no hay nada
seleccionado, todas las imágenes visibles. En el visor, usa la imagen en
pantalla. Las herramientas que crean imágenes, y el pase de diapositivas,
omiten los vídeos.

## Pase de diapositivas

**Herramientas > Iniciar pase de diapositivas** reproduce las imágenes a
pantalla completa, con HDR como en el visor. Se abre en la pantalla que elige
**El visor a pantalla completa se abre en** en **Ajustes > Visor**. Si empiezas
desde una sola imagen seleccionada, se reproduce toda la carpeta a partir de
ella.

- **Espacio** pone en pausa y reanuda, las teclas de flecha avanzan y
  retroceden, y **Esc** termina el pase. Mueve el puntero para que aparezca la
  barra de controles.
- Elige el tiempo por diapositiva, el orden (en orden o aleatorio), si volver
  a empezar al final, los pies de foto y una de las ocho transiciones o una
  aleatoria en **Ajustes > Pase de diapositivas**.
- Añade también música allí: canciones MP3, AAC, WAV o AIFF, o carpetas que
  las contengan. La música se desvanece cuando termina el pase.

### Exportar como vídeo

**Herramientas > Exportar vídeo del pase de diapositivas…** guarda el pase
como un archivo de vídeo, para reproducirlo o enviarlo a cualquier parte.

- Elige la resolución (720p, 1080p, 4K o la de tu pantalla), la frecuencia
  de fotogramas, el códec (H.264, o HEVC para archivos más pequeños), la
  calidad, y MP4 o MOV.
- El vídeo usa el tiempo por diapositiva, la transición, el orden, los pies
  de foto y la música definidos en **Ajustes > Pase de diapositivas**. Cada
  imagen aparece una vez.
- El vídeo es de rango dinámico estándar: las fotos HDR se convierten con
  mapeo de tonos.
- Exportar… pregunta dónde guardarlo. A continuación aparece una barra de
  progreso con el botón Cancelar.

## Conversión por lotes

**Herramientas > Convertir por lotes…** guarda copias de muchas imágenes en
otro formato.

- Elige el formato y sus opciones, como en Guardar como, y un destino: una
  carpeta, o junto a los originales. **Eliminar ubicación** omite la
  posición GPS en las copias; empieza activado.
- Si quieres, renombra las copias con un patrón, redimensiónalas (por el lado
  largo, la anchura, la altura o un porcentaje), gíralas o voltéalas, y
  conserva o elimina sus metadatos.
- **Ediciones** enumera las ediciones del preajuste elegido, creado en el
  visor con **Archivo > Guardar ediciones como preajuste…**, y las aplica a
  todas las imágenes. **Marca de agua** añade una marca de agua. Consulta
  [Edición](help:Editing) y [Efectos y retoque](help:Effects).
- **Conservar HDR** mantiene en HDR las fotos HDR en JPEG, HEIC y AVIF.
  Necesita el perfil de color Conservar el original o Display P3, y 8 bits;
  si no, las fotos HDR se escriben en rango dinámico estándar, y la hoja lo
  indica.
- **Preajuste**, en la parte superior, conserva todas las opciones con un
  nombre, para volver a usarlas.
- La conversión se ejecuta en segundo plano con una barra de progreso y el
  botón Cancelar, y enumera los archivos que no se hayan podido convertir.
- minivu pregunta antes de reemplazar nada, y un archivo reemplazado va a la
  papelera.

**Archivos multipágina** elige qué ocurre con los PDF, los TIFF multipágina
y las animaciones: **Solo la primera página** o **Todas las páginas**. Todas
las páginas crea un único archivo con todas las páginas en TIFF y GIF, y un
archivo por página en los demás formatos.

## Renombrar por lotes

**Herramientas > Renombrar por lotes…** renombra muchos archivos a la vez a
partir de un patrón de texto y elementos: el nombre original, un contador, la
fecha de captura, la fecha de modificación, el tamaño en píxeles y la
extensión. Añade buscar y reemplazar y un formato de mayúsculas y minúsculas,
y revisa la lista en vivo de antes y después, que señala los conflictos antes
de cambiar nada. Todo el cambio de nombre es un único paso de **Edición >
Deshacer**. Un **Preajuste** conserva un patrón con un nombre.

## Páginas y tiras

- **Herramientas > Extraer páginas…** guarda cada página de un PDF o de un
  TIFF multipágina, o cada fotograma de una animación, como un archivo
  independiente. Elige todas las páginas o un intervalo, y el formato, como
  en Conversión por lotes. Los nombres usan el elemento `{page}`, el número
  de página: “scan-03.png”.
- **Herramientas > Crear archivo multipágina…** une las imágenes en un solo
  archivo: un TIFF multipágina, un PDF, un GIF animado o, si tu Mac puede
  escribirlo, un HEIC animado. Arrastra la lista para cambiar el orden.
- **Herramientas > Tira de imágenes…** une las imágenes en una sola imagen,
  una al lado de otra, una encima de otra o en una cuadrícula, con la
  separación y el fondo que elijas. La tira se abre en el visor.

## Buscar duplicados

**Herramientas > Buscar duplicados…** busca copias entre las imágenes
seleccionadas, en la carpeta o en la carpeta y sus subcarpetas.

- **Archivos idénticos** encuentra archivos con exactamente el mismo
  contenido. **Imágenes similares** encuentra imágenes que se parecen, como
  copias redimensionadas, ediciones y ráfagas. Mueve el regulador
  **Similitud** para que sea más estricto o más flexible.
- En cada grupo, minivu sugiere un archivo que conservar: el de mayor
  resolución, el más grande o el más antiguo, según elijas. **Señalar los
  sugeridos** señala todos los demás; no se señala nada hasta que lo pidas.
- **Trasladar a la papelera…** traslada a la papelera los archivos
  señalados, después de preguntar. **Mostrar en el explorador** y
  **Comparar** muestran los archivos encontrados.

## Imprimir y Ajustar página

**Archivo > Imprimir…** usa el panel de impresión estándar con las opciones de
disposición de minivu: imágenes por página, ajustar o rellenar, girar las
imágenes para rellenar las celdas, márgenes, espaciado y pies de foto, con
una previsualización en vivo. **Archivo > Ajustar página…** elige el papel.

## Hoja de contactos

**Herramientas > Hoja de contactos…** distribuye miniaturas en páginas:
columnas, filas, espaciado, pies de foto, un encabezado, el tamaño de página
y el fondo. Guárdala como JPEG, PNG, TIFF o un PDF multipágina.

## Galería web

**Herramientas > Crear galería web…** crea una carpeta de páginas web que
muestran las imágenes: una página de miniaturas y una página para cada imagen
con enlaces a la anterior y a la siguiente. Abre su index.html en cualquier
navegador web, desde tu Mac o después de copiar la carpeta a un sitio web.

- Elige el título, los tamaños de las miniaturas y de las imágenes, las
  columnas, un tema claro, oscuro o automático, el orden y los pies de foto.
- Las imágenes son JPEG, HEIC (solo Safari) o AVIF. Se pueden conservar los
  metadatos, y **Eliminar ubicación** empieza activado. **Incluir los
  archivos originales** añade un enlace de descarga para cada original.
- Las páginas no usan scripts y no cargan nada de internet.

## Fondo de pantalla de montaje y fondo de pantalla

- **Herramientas > Fondo de pantalla de montaje…** crea un collage de las
  imágenes del tamaño de tu pantalla, como una cuadrícula, un mosaico o fotos
  dispersas, y lo establece como fondo de pantalla. Los montajes se guardan en
  **Imágenes/minivu Wallpapers**.
- **Herramientas > Establecer como fondo de pantalla** usa una imagen tal como
  está.

## Captura

**Herramientas > Captura** toma una imagen de toda la pantalla, de una ventana o
de una selección que arrastres (al soltar el ratón se captura, **Esc** cancela).
Las capturas se guardan como archivos PNG en **Imágenes/minivu Captures** y se
abren en el visor.

Capturar toda la pantalla o una selección requiere el permiso de Grabación de
pantalla. macOS lo pide la primera vez; puedes cambiarlo después en **Ajustes
del Sistema > Privacidad y seguridad > Grabación de pantalla y audio del
sistema**. Elegir una ventana en el selector de ventanas del sistema no
requiere ningún permiso.

## Editores externos

**Herramientas > Abrir en editor externo** envía las imágenes seleccionadas, o
la imagen que se muestra, a otra app. El primer editor de la lista es **⌘E**.
Elige **Editar lista de editores…** para añadir apps en **Ajustes >
Editores**.

Cuando un editor guarda un archivo, minivu muestra la nueva versión. Si tenías
ediciones sin guardar de ese archivo en minivu, te pregunta si quieres
conservarlas o volver a cargarlo.

## Atajos

minivu añade acciones a la app Atajos: **Convertir imágenes**, **Redimensionar
imágenes**, **Renombrar imágenes**, **Asignar valoración**, **Asignar etiqueta
de color** y **Abrir en minivu**. Busca “minivu” entre las acciones de la app
Atajos para usarlas en tus propios atajos. Al ejecutar uno de esos atajos,
minivu se abre si no estaba abierto. Las acciones solo funcionan con archivos
del almacenamiento interno de tu Mac. **Renombrar imágenes** solo funciona en tu
carpeta Imágenes y en las carpetas de la barra lateral de minivu; si algún
archivo está en otro sitio, no renombra ninguno.

Para usar un atajo desde el Finder, crea uno que reciba imágenes y activa **Usar
como acción rápida** en sus detalles. Entonces aparece en el menú contextual del
Finder, en **Acciones rápidas**.
