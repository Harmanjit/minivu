# Privacidad

## Sin red

minivu nunca se conecta a internet. Se ejecuta en el App Sandbox sin el
permiso de red, así que macOS no le deja abrir ninguna conexión. No hay
cuenta, ni análisis, ni informes de fallos, ni comprobación de
actualizaciones, y esta ayuda forma parte de la app.

Texto en vivo, Eliminar fondo, Copiar sujeto, la detección de ojos rojos, el
botón Auto de Perspectiva y la opción Imágenes similares de Buscar duplicados
usan el framework Vision de Apple, en tu Mac. No se envía nada a ninguna
parte.

**Archivo > Compartir…** entrega los archivos al servicio para compartir que
elijas, como AirDrop o Mail, que es el que los envía. minivu no abre ninguna
conexión por sí mismo.

## Qué puede ver minivu

El sandbox limita minivu a:

- tu carpeta **Imágenes**;
- las carpetas y archivos que elijas en un panel Abrir o Guardar, sueltes
  sobre minivu o abras con minivu desde Finder;
- las carpetas de su barra lateral y las carpetas recientes de Copiar en y
  Trasladar a, que recuerda con marcadores que solo este Mac y esta app pueden
  usar;
- una imagen elegida para una marca de agua, que recuerda con un marcador de
  solo lectura;
- su propio contenedor, `~/Library/Containers/com.minivu.app`.

Solo funciona con el almacenamiento interno de tu Mac, no con tarjetas de
memoria, discos externos ni recursos compartidos de red.

## Qué guarda minivu

En su contenedor, solo en tu Mac:

- **El catálogo** de valoraciones con estrellas, marcas, órdenes
  personalizados, colecciones, carpetas inteligentes y la información de las
  fotos leída para los filtros y las búsquedas.
- **La caché de miniaturas**, con las huellas que crea Buscar duplicados, que
  se vacía con **Ajustes > Miniaturas > Borrar caché de miniaturas**.
- **Los ajustes**, incluidas las carpetas de la barra lateral, las carpetas
  recientes, la música de los pases de diapositivas, los editores externos y
  los preajustes.

Las búsquedas solo leen carpetas que minivu puede ver, en tu Mac. minivu no
consulta Spotlight.

## Qué cambia minivu en tus archivos

Solo lo que le pidas:

- **Guardar** escribe sobre el original, después de preguntar. **Guardar
  como**, Conversión por lotes, Extraer páginas, Crear archivo multipágina,
  Tira de imágenes, Hoja de contactos, Montaje, Exportar vídeo del pase de
  diapositivas y Crear galería web crean archivos nuevos.
- Girar y voltear en el explorador cambian la etiqueta de orientación de un
  JPEG, y Editar comentario cambia su comentario.
- **Editar metadatos** escribe la información que cambies en el archivo, o en
  un archivo auxiliar XMP junto a él.
- **Imagen > Etiqueta** asigna la etiqueta de color de Finder del archivo.
  Las estrellas y las marcas solo se escriben en los archivos si activas
  **Escribir las valoraciones en los archivos (XMP)** en Ajustes.
- Una acción de minivu en la app Atajos puede convertir, redimensionar,
  renombrar, valorar o etiquetar archivos que minivu tiene permiso para
  modificar.
- Renombrar, Trasladar, Copiar, Nueva carpeta y Renombrar por lotes cambian
  nombres y carpetas, y se pueden deshacer.
- **Trasladar a la papelera**, y reemplazar un archivo con el mismo nombre,
  ponen los ítems en la papelera. minivu no elimina tus archivos.
- Los archivos se escriben primero por completo y después se colocan en su
  sitio, así que un guardado interrumpido nunca deja medio archivo.

**Ubicación.** Guardar como, Conversión por lotes, Crear galería web y las
acciones de Atajos omiten la posición GPS y los nombres de lugar, a menos que
desactives **Eliminar ubicación**. Guardar lo conserva todo, ubicación
incluida. La ubicación de un vídeo se muestra, pero nunca se elimina.

minivu también escribe en **Imágenes/minivu Captures** (capturas de pantalla)
y en **Imágenes/minivu Wallpapers** (montajes y copias creadas para Establecer
como fondo de pantalla, de las que conserva las diez más recientes).

## Permisos

- **Grabación de pantalla**, solo si usas Captura > Toda la pantalla o
  Selección. Puedes desactivarla en Ajustes del Sistema > Privacidad y
  seguridad.
- **Impresión**, mediante el panel de impresión estándar.
