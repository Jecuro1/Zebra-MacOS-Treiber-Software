/*
 * ppdcheck – Prüfprogramm für die von generate_ppds.py erzeugten PPD-Dateien.
 *
 * Öffnet eine PPD (auch .ppd.gz) mit libcups – also genau dem Parser, den cupsd und die
 * Filter verwenden – und gibt alles, was die Tests in test_generate.py brauchen, als
 * tabulatorgetrennte Zeilen aus:
 *
 *   ATTR      <name> <spec> <wert>                       alle Hauptschlüsselwörter
 *   GROUP     <name> <text>                              Gruppen (vor der Lokalisierung)
 *   OPTION    <schlüssel> <ui> <standard> <gruppe> <text>
 *   CHOICE    <schlüssel> <wahl> <text>
 *   CPARAM    <option> <param> <typ> <min> <max>         Parameter eigener Seitengrößen
 *   SIZE      <name> <breite> <länge> <links> <unten> <rechts> <oben>
 *   RASTER    <größe> <hwres-x> <hwres-y> <cupsWidth> <cupsHeight> <farbraum> <bits> <bytes/zeile>
 *   CUSTOM    <angabe> <breite> <länge> <cupsWidth> <cupsHeight>
 *   CONFLICTS <anzahl>                                   Konflikte der Standardauswahl
 *   LOCALE    <sprache>                                  von ppdLocalize verwendete Sprache
 *   LGROUP / LOPTION / LCHOICE / LCUSTOM / LPARAM        lokalisierte Texte (UTF-8)
 *   ERROR     <beschreibung>                             Abbruch (Exit-Status 2)
 *
 * Die Sprache für ppdLocalize kommt aus der Umgebung: LANG=de_DE.UTF-8 und zusätzlich SOFTWARE
 * (beliebiger Wert, z. B. CUPS/2.3) – die libcups von macOS beachtet LANG nur bei gesetztem
 * SOFTWARE und nimmt sonst die Systemsprache des Benutzers (AppleLanguages). LC_ALL,
 * LC_MESSAGES und LANGUAGE dürfen nicht gesetzt sein (siehe cups_environment in generate_ppds.py).
 *
 * Bauen:  cc -std=c99 -Wall -Wextra -Wno-deprecated-declarations ppdcheck.c -o ppdcheck -lcups
 * Aufruf: ppdcheck <datei.ppd[.gz]> [eigene-größe …]    z. B. Custom.100x150mm
 */

#include <cups/cups.h>
#include <cups/ppd.h>
#include <cups/raster.h>
#include <cups/language.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Gibt einen Text aus und ersetzt Tabulatoren/Zeilenumbrüche (dürfen in PPD-Texten nicht vorkommen). */
static void put_text(const char *text)
{
    for (const char *p = text != NULL ? text : ""; *p != '\0'; p++)
        putchar((*p == '\t' || *p == '\n' || *p == '\r') ? ' ' : *p);
}

static const char *ui_name(ppd_ui_t ui)
{
    switch (ui) {
    case PPD_UI_BOOLEAN: return "Boolean";
    case PPD_UI_PICKONE: return "PickOne";
    case PPD_UI_PICKMANY: return "PickMany";
    }
    return "?";
}

static const char *cparam_type_name(ppd_cptype_t type)
{
    switch (type) {
    case PPD_CUSTOM_CURVE: return "curve";
    case PPD_CUSTOM_INT: return "int";
    case PPD_CUSTOM_INVCURVE: return "invcurve";
    case PPD_CUSTOM_PASSCODE: return "passcode";
    case PPD_CUSTOM_PASSWORD: return "password";
    case PPD_CUSTOM_POINTS: return "points";
    case PPD_CUSTOM_REAL: return "real";
    case PPD_CUSTOM_STRING: return "string";
    default: return "unknown";
    }
}

static void print_attrs(ppd_file_t *ppd)
{
    for (int i = 0; i < ppd->num_attrs; i++) {
        ppd_attr_t *attr = ppd->attrs[i];
        fputs("ATTR\t", stdout);
        put_text(attr->name);
        putchar('\t');
        put_text(attr->spec);
        putchar('\t');
        put_text(attr->value);
        putchar('\n');
    }
}

static void print_options(ppd_file_t *ppd, const char *prefix)
{
    ppd_group_t *group = ppd->groups;
    for (int g = 0; g < ppd->num_groups; g++, group++) {
        printf("%sGROUP\t%s\t", prefix, group->name);
        put_text(group->text);
        putchar('\n');
        ppd_option_t *option = group->options;
        for (int o = 0; o < group->num_options; o++, option++) {
            if (prefix[0] == '\0') {
                printf("OPTION\t%s\t%s\t%s\t%s\t", option->keyword, ui_name(option->ui),
                       option->defchoice, group->name);
            } else {
                printf("%sOPTION\t%s\t", prefix, option->keyword);
            }
            put_text(option->text);
            putchar('\n');
            for (int c = 0; c < option->num_choices; c++) {
                printf("%sCHOICE\t%s\t%s\t", prefix, option->keyword, option->choices[c].choice);
                put_text(option->choices[c].text);
                putchar('\n');
            }
        }
    }
}

static void print_custom(ppd_file_t *ppd, const char *prefix)
{
    ppd_coption_t *coption = ppdFindCustomOption(ppd, "PageSize");
    if (coption == NULL)
        return;
    for (ppd_cparam_t *p = ppdFirstCustomParam(coption); p != NULL; p = ppdNextCustomParam(coption)) {
        if (prefix[0] != '\0') {
            printf("%sPARAM\tPageSize\t%s\t", prefix, p->name);
            put_text(p->text);
            putchar('\n');
            continue;
        }
        double low = 0.0, high = 0.0;
        if (p->type == PPD_CUSTOM_POINTS) {
            low = p->minimum.custom_points;
            high = p->maximum.custom_points;
        } else if (p->type == PPD_CUSTOM_INT) {
            low = p->minimum.custom_int;
            high = p->maximum.custom_int;
        } else if (p->type == PPD_CUSTOM_REAL) {
            low = p->minimum.custom_real;
            high = p->maximum.custom_real;
        }
        printf("CPARAM\tPageSize\t%s\t%s\t%.3f\t%.3f\n", p->name, cparam_type_name(p->type), low, high);
    }
    if (prefix[0] != '\0') {
        ppd_choice_t *custom = ppdFindChoice(ppdFindOption(ppd, "PageSize"), "Custom");
        if (custom != NULL) {
            printf("%sCUSTOM\tPageSize\t", prefix);
            put_text(custom->text);
            putchar('\n');
        }
    }
}

/* Rasterkopf für die aktuell markierten Optionen berechnen und ausgeben. */
static int print_raster(ppd_file_t *ppd, const char *tag, const char *name)
{
    cups_page_header2_t header;
    memset(&header, 0, sizeof(header));
    if (cupsRasterInterpretPPD(&header, ppd, 0, NULL, NULL) != 0) {
        printf("ERROR\tcupsRasterInterpretPPD fehlgeschlagen für %s: %s\n", name, cupsLastErrorString());
        return 0;
    }
    printf("%s\t%s\t%u\t%u\t%u\t%u\t%u\t%u\t%u\n", tag, name, header.HWResolution[0],
           header.HWResolution[1], header.cupsWidth, header.cupsHeight, (unsigned)header.cupsColorSpace,
           header.cupsBitsPerColor, header.cupsBytesPerLine);
    return 1;
}

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Aufruf: %s datei.ppd[.gz] [Custom.BxHmm …]\n", argv[0]);
        return 1;
    }

    ppd_file_t *ppd = ppdOpenFile(argv[1]);
    if (ppd == NULL) {
        int line = 0;
        ppd_status_t status = ppdLastError(&line);
        printf("ERROR\tppdOpenFile: %s (Zeile %d)\n", ppdErrorString(status), line);
        return 2;
    }

    ppdMarkDefaults(ppd);
    printf("CONFLICTS\t%d\n", ppdConflicts(ppd));

    print_attrs(ppd);
    print_options(ppd, "");
    print_custom(ppd, "");

    for (int i = 0; i < ppd->num_sizes; i++) {
        ppd_size_t *s = ppd->sizes + i;
        printf("SIZE\t%s\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\n", s->name, s->width, s->length, s->left,
               s->bottom, s->right, s->top);
    }

    /* Rasterkopf je Seitengröße (wie cupsd/cgpdftoraster ihn aus der PPD bilden). */
    int ok = 1;
    for (int i = 0; i < ppd->num_sizes; i++) {
        const char *name = ppd->sizes[i].name;
        if (strcmp(name, "Custom") == 0)
            continue;
        ppdMarkOption(ppd, "PageSize", name);
        ok &= print_raster(ppd, "RASTER", name);
    }

    /* Eigene Seitengrößen (z. B. Custom.100x150mm). */
    for (int a = 2; a < argc; a++) {
        ppdMarkOption(ppd, "PageSize", argv[a]);
        ppd_size_t *size = ppdPageSize(ppd, argv[a]);
        cups_page_header2_t header;
        memset(&header, 0, sizeof(header));
        if (size == NULL || cupsRasterInterpretPPD(&header, ppd, 0, NULL, NULL) != 0) {
            printf("ERROR\teigene Größe %s nicht verwendbar\n", argv[a]);
            ok = 0;
            continue;
        }
        printf("CUSTOM\t%s\t%.3f\t%.3f\t%u\t%u\n", argv[a], size->width, size->length, header.cupsWidth,
               header.cupsHeight);
    }
    ppdMarkDefaults(ppd);

    /* Lokalisierung wie im macOS-Druckdialog bzw. in cupsd. */
    cups_lang_t *lang = cupsLangDefault();
    printf("LOCALE\t%s\n", lang != NULL ? lang->language : "");
    if (ppdLocalize(ppd) != 0) {
        printf("ERROR\tppdLocalize fehlgeschlagen\n");
        ok = 0;
    } else {
        print_options(ppd, "L");
        print_custom(ppd, "L");
    }

    ppdClose(ppd);
    return ok ? 0 : 2;
}
