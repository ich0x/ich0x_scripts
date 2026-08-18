# Traducciones para Setup_Automount_CajaSegura_zswap

Este proyecto soporta 3 formatos de traducción. Prioridad: 1. mo  2. txt  3. xml

## Opción 1: TXT - Más fácil [Recomendado para usuarios]
1. Copia `l10n/user/Setup_Automount_CajaSegura_zswap.es.txt` a `~/Translations/Setup_Automount_CajaSegura_zswap.fr.txt`
2. Traduce solo la parte derecha del `=`
3. Guarda. Listo. No necesitas sudo ni compilar.

## Opción 2: XML - Para paquetería
1. Copia `l10n/system/Setup_Automount_CajaSegura_zswap.es.xml` a `Setup_Automount_CajaSegura_zswap.fr.xml`
2. Traduce los `value=""`
3. Instalar en: `/usr/share/Setup_Automount_CajaSegura_zswap/l10n/`

## Opción 3: .po/.mo - Para Poedit y estándar GNU
1. `msginit -i Setup_Automount_CajaSegura_zswap.pot -l fr_FR -o fr.po`
2. Abre con Poedit y traduce
3. `msgfmt fr.po -o /usr/share/locale/fr/LC_MESSAGES/Setup_Automount_CajaSegura_zswap.mo`

## Agregar nuevas cadenas
Si agregas `tr "Nuevo Texto"` al script, agrégalo también a los 3 archivos de plantilla.
