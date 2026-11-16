# Privacidad

## Sin red

minivu nunca se conecta a internet. Se ejecuta en el App Sandbox sin el
permiso de red, así que macOS no le deja abrir ninguna conexión. No hay
cuenta, ni análisis, ni informes de fallos, ni comprobación de
actualizaciones, y esta ayuda forma parte de la app.

## Qué puede ver minivu

El sandbox limita minivu a:

- tu carpeta **Imágenes**;
- las carpetas y archivos que elijas en un panel Abrir o Guardar, sueltes
  sobre minivu o abras con minivu desde Finder;
- las carpetas de su barra lateral y las carpetas recientes de Copiar en y
  Trasladar a, que recuerda con marcadores que solo este Mac y esta app pueden
  usar;
- su propio contenedor, `~/Library/Containers/com.minivu.app`.

Solo funciona con el almacenamiento interno de tu Mac, no con tarjetas de
memoria, discos externos ni recursos compartidos de red.

## Qué guarda minivu

En su contenedor, solo en tu Mac:

- **El catálogo** de valoraciones con estrellas, marcas y órdenes
  personalizados.
- **La caché de miniaturas**, que se vacía con **Ajustes > Miniaturas >
  Borrar caché de miniaturas**.
- **Los ajustes**, incluidas las carpetas de la barra lateral, las carpetas
  recientes, la música de los pases de diapositivas y los editores externos.

## Qué cambia minivu en tus archivos

Solo lo que le pidas:

- **Guardar** escribe sobre el original, después de preguntar. **Guardar
  como**, Conversión por lotes, Hoja de contactos y Montaje crean archivos
  nuevos.
- Girar y voltear en el explorador cambian la etiqueta de orientación de un
  JPEG, y Editar comentario cambia su comentario.
- Renombrar, Trasladar, Copiar, Nueva carpeta y Renombrar por lotes cambian
  nombres y carpetas, y se pueden deshacer.
- **Trasladar a la papelera**, y reemplazar un archivo con el mismo nombre,
  ponen los ítems en la papelera. minivu no elimina tus archivos.
- Los archivos se escriben primero por completo y después se colocan en su
  sitio, así que un guardado interrumpido nunca deja medio archivo.

minivu también escribe en **Imágenes/minivu Captures** (capturas de pantalla)
y en **Imágenes/minivu Wallpapers** (montajes y copias creadas para Establecer
como fondo de pantalla, de las que conserva las diez más recientes).

## Permisos

- **Grabación de pantalla**, solo si usas Captura > Toda la pantalla o
  Selección. Puedes desactivarla en Ajustes del Sistema > Privacidad y
  seguridad.
- **Impresión**, mediante el panel de impresión estándar.

La detección de ojos rojos encuentra las caras con el framework Vision de
Apple, en tu Mac.
