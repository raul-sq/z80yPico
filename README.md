# Z80yPico

## Descripción general

**Z80yPico** es un proyecto experimental de retrocomputación cuyo objetivo es construir un ordenador basado en un **microprocesador Z80**, apoyado por una **Raspberry Pi Pico** como coprocesador para tareas modernas de entrada/salida.

La idea central del proyecto es conservar la arquitectura mental de un ordenador clásico de 8 bits —CPU Z80, ROM, RAM, firmware, comandos, editor y BASIC— pero delegando en la Pico las funciones que en una máquina histórica requerirían circuitería adicional compleja: vídeo, teclado, almacenamiento, servicios de sistema y periféricos.

El proyecto parte de una premisa clara:

> El Z80 debe comportarse como la CPU principal del sistema, mientras que la Pico actúa como apoyo para servicios de hardware y sistema.

Esta filosofía busca evitar que la Pico sustituya conceptualmente al Z80. La Pico no es “el ordenador” y el Z80 no es un adorno: el objetivo es diseñar una máquina donde el Z80 conserve el protagonismo lógico.

---

## Objetivo del proyecto

Z80yPico pretende servir como banco de pruebas para:

- Diseñar una arquitectura de ordenador Z80 moderno.
- Experimentar con firmware modular en ensamblador Z80.
- Implementar servicios de sistema inspirados en máquinas clásicas.
- Construir un editor de texto residente.
- Desarrollar un BASIC propio o adaptado al entorno Z80yPico.
- Probar comandos externos cargables.
- Explorar una futura implementación física con ROM, RAM y Raspberry Pi Pico.

La visión a largo plazo es disponer de una máquina estilo retroordenador, con una experiencia cercana a sistemas clásicos como ZX Spectrum, CP/M, MSX o microordenadores educativos, pero con un subsistema moderno de apoyo.

---

## Arquitectura conceptual prevista

La arquitectura final se concibe con los siguientes bloques:

```text
+-------------------+
|       Z80 CPU     |
+-------------------+
          |
          | bus de direcciones / datos / control
          |
+-------------------+        +-----------------------+
|        ROM        |        |          RAM          |
| firmware / BASIC  |        | programas / datos     |
+-------------------+        +-----------------------+
          |
          |
+----------------------------------------------------+
|                Interfaz con Raspberry Pi Pico       |
+----------------------------------------------------+
          |
          |
+-------------------+  +------------------+  +----------------+
|      Vídeo        |  |     Teclado      |  | Almacenamiento |
| texto / gráficos  |  | PS/2 u otro      |  | microSD / FS   |
+-------------------+  +------------------+  +----------------+
```

En esta arquitectura:

- El **Z80** ejecuta el firmware principal, comandos y programas.
- La **ROM** contendría el BIOS, rutinas de firmware, intérprete BASIC y comandos esenciales.
- La **RAM** alojaría el estado de ejecución, programas BASIC, buffers, pila y estructuras dinámicas.
- La **Pico** ofrecería servicios de vídeo, teclado, almacenamiento y comunicación con el exterior.
- El firmware Z80 se organizaría en módulos relativamente pequeños, reutilizables y comprobables.

---

## Implementación previa en emulador

Antes de pasar a una implementación física completa, el proyecto se ha desarrollado sobre una implementación previa en **emulador Python**.

Esta etapa es fundamental porque permite validar la arquitectura del firmware, los comandos, el editor y el BASIC sin depender todavía de una placa física completa.

El emulador actúa como un entorno de integración donde:

- Python proporciona el motor de ejecución y el entorno anfitrión.
- Los módulos Z80 se ensamblan en binarios `.bin`.
- El emulador carga y ejecuta rutinas Z80.
- El código Python simula parte de los servicios que más adelante podrían residir en la Pico.
- Las rutinas Z80 interactúan con el entorno mediante contratos de llamada definidos.
- Se prueban comandos, editor, entrada de línea, impresión, pantalla y ejecución BASIC.

Dicho de forma sencilla:

> El emulador Python funciona como una primera “Pico virtual”, mientras que los binarios Z80 ASM representan el firmware que posteriormente podría migrar hacia una máquina física.

---

## Motor Python con llamadas a Z80 ASM

Uno de los aspectos más importantes de esta implementación es que no se trata simplemente de un programa Python que “imita” un ordenador Z80 desde fuera.

La aproximación seguida combina:

1. **Motor Python**
   - Gestiona el entorno de ejecución.
   - Carga módulos binarios.
   - Coordina pantalla, teclado, comandos y estado del sistema.
   - Sirve como banco de pruebas del contrato BIOS/firmware.

2. **Módulos Z80 ASM**
   - Implementan comandos y rutinas de firmware.
   - Se ensamblan a `.bin`.
   - Son invocados desde el entorno del emulador.
   - Mantienen una separación clara entre lógica Z80 y servicios externos.

3. **Contrato entre ambos mundos**
   - El firmware Z80 espera determinadas rutinas o servicios.
   - Python implementa o simula esos servicios.
   - Esto permite depurar la interfaz antes de llevarla a hardware real.

Esta separación es importante porque obliga a pensar el sistema como una arquitectura real, no solo como una simulación informal.

---

## Componentes principales del repositorio

El repositorio inicial contiene una colección de binarios, fuentes y recursos esenciales para el estado actual del proyecto.

### Emulador

- `Z80yPicoPartialEmulator60.py`

Motor Python actual del emulador parcial de Z80yPico. Sirve como entorno anfitrión para probar la integración entre el sistema, el editor, el BASIC y los módulos ensamblados.

### BASIC

- `z80ypico_basic.asm`
- `z80ypico_basic.bin`
- `z80ypico_basic.o`

Implementación actual del núcleo BASIC en ensamblador Z80, junto con su binario ensamblado y objeto intermedio.

### Flujo editor/BASIC

- `EDITOR_BASIC_WORKFLOW_01.asm`
- `EDITOR_BASIC_WORKFLOW_01.bin`
- `EDITOR_BASIC_WORKFLOW_01.o`

Código relacionado con el flujo de trabajo entre editor y BASIC. Esta parte es especialmente importante porque el proyecto no se limita a ejecutar comandos aislados: busca una experiencia completa de edición, carga, modificación y ejecución de programas.

### Firmware modular

Archivos como:

- `FW_PRINT.bin`
- `FW_PUTCHAR.bin`
- `FW_GETKEY.bin`
- `FW_INPUTLINE.bin`
- `FW_TEXTEDITOR_NOWRAP_24_SUPR.bin`
- `FW_CLS.bin`
- `FW_LOCATE.bin`
- `FW_DIR.bin`
- `FW_PWD.bin`
- `FW_STATUS.bin`
- `FW_BORDER.bin`
- `FW_INK.bin`
- `FW_PAPER.bin`
- `FW_BRIGHT.bin`
- `FW_FLASH.bin`
- `FW_WRAP.bin`

Estos módulos representan rutinas de firmware o servicios básicos del sistema. La intención es que el firmware pueda crecer por capas, evitando concentrar toda la lógica en un único bloque monolítico.

### Comandos

Archivos como:

- `CMD_HELP.bin`
- `CMD_DIR.bin`
- `CMD_PWD.bin`
- `CMD_STATUS.bin`
- `CMD_CLS.bin`
- `CMD_NEW.bin`
- `CMD_RUN.bin`
- `CMD_RESET.bin`
- `CMD_BIOS.bin`
- `CMD_BORDER.bin`
- `CMD_INK.bin`
- `CMD_PAPER.bin`
- `CMD_BRIGHT.bin`
- `CMD_FLASH.bin`
- `CMD_PALETTE.BIN`

Estos binarios representan comandos ejecutables dentro del entorno Z80yPico. La existencia de comandos separados permite probar una arquitectura extensible, más cercana a un sistema real que a una simple demo cerrada.

### Ejemplos BASIC

Directorio:

- `Examples/`

Con programas de prueba como:

- `goto.bas`
- `goto2.bas`
- `goto3.bas`
- `loop.bas`

Estos ejemplos sirven para verificar instrucciones, control de flujo y comportamiento del intérprete BASIC.

### Recursos auxiliares

- `charset.bin`
- `z80_decode_v3.csv`
- `z80ypico_palette_v1.pal`

Estos archivos proporcionan recursos de apoyo para caracteres, decodificación o paleta de colores.

---

## Estado actual del proyecto

En su estado actual, Z80yPico es principalmente:

- Un entorno experimental.
- Un prototipo de arquitectura.
- Una implementación parcial en emulador.
- Un conjunto de módulos Z80 ASM ya ensamblados.
- Un banco de pruebas para firmware, comandos, editor y BASIC.

No debe entenderse todavía como una máquina física terminada, sino como una fase previa sólida para validar decisiones de diseño antes de trasladarlas al hardware.

---

## Filosofía de diseño

El proyecto sigue varias ideas guía:

### 1. Arquitectura antes que improvisación

Antes de conectar componentes físicos, se busca definir bien:

- Qué hace el Z80.
- Qué hace la Pico.
- Qué rutinas pertenecen al firmware.
- Qué contratos de llamada deben respetarse.
- Cómo se comunican los comandos con el sistema.

### 2. Firmware modular

El sistema se divide en bloques pequeños:

- Rutinas de impresión.
- Entrada de teclado.
- Limpieza de pantalla.
- Localización del cursor.
- Comandos externos.
- Editor.
- BASIC.

Esto facilita probar, sustituir y depurar cada componente.

### 3. Emulador como laboratorio

El emulador no es un objetivo final en sí mismo, sino una herramienta de desarrollo.

Permite detectar errores de contrato, problemas de flujo, fallos en comandos, inconsistencias del editor o errores del BASIC antes de enfrentarse a las dificultades adicionales del hardware.

### 4. Z80 como protagonista

Aunque la Raspberry Pi Pico sea mucho más potente que el Z80, el objetivo conceptual es que la Pico actúe como coprocesador o subsistema auxiliar.

La gracia del proyecto está precisamente en mantener al Z80 como centro de la máquina.

---

## Posible evolución futura

Algunas líneas naturales de evolución del proyecto son:

- Documentar formalmente el contrato BIOS/firmware.
- Separar con más claridad los módulos de comandos, firmware y BASIC.
- Añadir documentación de ensamblado y ejecución.
- Crear una tabla de memoria del sistema.
- Definir mapa de ROM y RAM.
- Implementar pruebas automáticas para programas BASIC de ejemplo.
- Preparar una futura placa física con Z80, ROM, RAM y Pico.
- Explorar salida de vídeo mediante Pico.
- Explorar teclado PS/2 u otro sistema de entrada.
- Diseñar un sistema de almacenamiento basado en microSD.
- Integrar más comandos del sistema.
- Avanzar hacia una ROM completa de Z80yPico.

---

## Relación entre emulador y futura máquina física

La implementación actual en Python puede verse como una etapa de transición:

```text
Fase actual:
Python + binarios Z80 ASM
        |
        v
Validación de firmware, comandos, editor y BASIC
        |
        v
Futura implementación:
Z80 físico + ROM + RAM + Raspberry Pi Pico
```

La ventaja de esta estrategia es que muchos errores de arquitectura pueden resolverse antes de trabajar con señales, buses, temporización, memorias reales y periféricos físicos.

---

## Conclusión

Z80yPico es un proyecto de retrocomputación experimental que combina el encanto de una arquitectura Z80 clásica con la flexibilidad de una Raspberry Pi Pico como coprocesador moderno.

La implementación previa en emulador Python permite avanzar de forma incremental, validando los módulos Z80 ASM, el firmware, los comandos, el editor y el BASIC antes de trasladar el sistema a hardware real.

El proyecto no busca simplemente “emular un Z80”, sino construir progresivamente una máquina con identidad propia: un ordenador Z80 moderno, modular, comprensible y ampliable.

---

## Autor

Proyecto desarrollado por **Raúl Santos Quirós**.

Repositorio: `raul-sq/z80yPico`

## Agradecimientos

Quisiera agradecer a Sergio Ucedo su ayuda para desarrollar la instrucción GOTO.
