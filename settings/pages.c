#define _GNU_SOURCE

#include "settings.h"

#include <glib/gstdio.h>
#include <pango/pango.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

static gint compare_strings(gconstpointer a, gconstpointer b)
{
    const gchar *left = *(const gchar *const *)a;
    const gchar *right = *(const gchar *const *)b;
    return g_strcmp0(left, right);
}

static gboolean config_set_int(BubbleSettings *s, const gchar *key, gint value)
{
    gchar number[32];

    g_snprintf(number, sizeof(number), "%d", value);
    return bubble_settings_config_set(s, key, number);
}

static GPtrArray *list_entries(const gchar *root, const gchar *required,
                               gboolean required_is_dir)
{
    GPtrArray *items = g_ptr_array_new_with_free_func(g_free);
    GDir *dir = g_dir_open(root, 0, NULL);

    if (dir == NULL) {
        return items;
    }
    const gchar *name;
    while ((name = g_dir_read_name(dir)) != NULL) {
        gchar *path;
        gboolean ok;

        if (name[0] == '.') {
            continue;
        }
        if (required == NULL) {
            ok = TRUE;
        } else {
            path = g_build_filename(root, name, required, NULL);
            ok = required_is_dir ? g_file_test(path, G_FILE_TEST_IS_DIR)
                                 : g_file_test(path, G_FILE_TEST_EXISTS);
            g_free(path);
        }
        if (ok) {
            g_ptr_array_add(items, g_strdup(name));
        }
    }
    g_dir_close(dir);
    g_ptr_array_sort(items, compare_strings);
    return items;
}

static gchar **ptr_array_to_strv(GPtrArray *items)
{
    g_ptr_array_add(items, NULL);
    return (gchar **)g_ptr_array_free(items, FALSE);
}

static void add_font_family(GPtrArray *fonts, GHashTable *seen,
                            const gchar *family)
{
    gchar *trimmed = g_strdup(family);
    gchar *end;

    g_strstrip(trimmed);
    if (*trimmed == '\0') {
        g_free(trimmed);
        return;
    }
    end = strchr(trimmed, ',');
    if (end != NULL) {
        *end = '\0';
        g_strchomp(trimmed);
    }
    if (*trimmed != '\0' && !g_hash_table_contains(seen, trimmed)) {
        g_hash_table_add(seen, g_strdup(trimmed));
        g_ptr_array_add(fonts, g_strdup(trimmed));
    }
    g_free(trimmed);
}

static GPtrArray *list_font_families(void)
{
    GPtrArray *fonts = g_ptr_array_new_with_free_func(g_free);
    GHashTable *seen = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    const gchar *fallbacks[] = {"Inter", "JetBrains Mono", "Orbitron",
                                "Noto Sans", "DejaVu Sans", NULL};
    gchar *out = NULL;
    gchar *err = NULL;
    gchar *argv[] = {"fc-list", ":", "family", NULL};
    gint status = 0;

    if (g_spawn_sync(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, &out,
                     &err, &status, NULL) &&
        WIFEXITED(status) && WEXITSTATUS(status) == 0 && out != NULL) {
        gchar **lines = g_strsplit(out, "\n", -1);
        for (guint i = 0; lines[i] != NULL; i++) {
            add_font_family(fonts, seen, lines[i]);
        }
        g_strfreev(lines);
    }
    for (guint i = 0; fallbacks[i] != NULL; i++) {
        add_font_family(fonts, seen, fallbacks[i]);
    }
    g_ptr_array_sort(fonts, compare_strings);
    g_hash_table_destroy(seen);
    g_free(out);
    g_free(err);
    return fonts;
}

static gchar *font_family_from_value(const gchar *value)
{
    gchar *copy = g_strdup(value != NULL ? value : "Inter 10");
    gchar *space = strrchr(copy, ' ');

    if (space != NULL && space != copy) {
        *space = '\0';
    }
    return copy;
}

static gint font_size_from_value(const gchar *value)
{
    gchar *copy = g_strdup(value != NULL ? value : "Inter 10");
    gchar *space = strrchr(copy, ' ');
    gint size = space != NULL ? atoi(space + 1) : 10;

    if (size < 6 || size > 48) {
        size = 10;
    }
    g_free(copy);
    return size;
}

static void add_page_title(GtkWidget *page, const gchar *title,
                           const gchar *subtitle)
{
    GtkWidget *label = gtk_label_new(title);
    GtkWidget *sub = gtk_label_new(subtitle);

    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_halign(sub, GTK_ALIGN_START);
    gtk_label_set_xalign(GTK_LABEL(sub), 0.0f);
    gtk_label_set_line_wrap(GTK_LABEL(sub), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(sub), 80);
    gtk_style_context_add_class(gtk_widget_get_style_context(label),
                                "page-title");
    gtk_style_context_add_class(gtk_widget_get_style_context(sub),
                                "page-subtitle");
    gtk_box_pack_start(GTK_BOX(page), label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), sub, FALSE, FALSE, 0);
}

GtkWidget *bubble_settings_page(const gchar *title, const gchar *subtitle)
{
    GtkWidget *page = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);

    gtk_widget_set_margin_start(page, 28);
    gtk_widget_set_margin_end(page, 28);
    gtk_widget_set_margin_top(page, 24);
    gtk_widget_set_margin_bottom(page, 28);
    gtk_widget_set_hexpand(page, TRUE);
    add_page_title(page, title, subtitle);
    return page;
}

GtkWidget *bubble_settings_card(const gchar *title)
{
    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);

    gtk_style_context_add_class(gtk_widget_get_style_context(card), "card");
    gtk_widget_set_hexpand(card, TRUE);
    if (title != NULL) {
        GtkWidget *label = gtk_label_new(title);
        gtk_widget_set_halign(label, GTK_ALIGN_START);
        gtk_style_context_add_class(gtk_widget_get_style_context(label),
                                    "card-title");
        gtk_box_pack_start(GTK_BOX(card), label, FALSE, FALSE, 0);
    }
    return card;
}

GtkWidget *bubble_settings_grid(void)
{
    GtkWidget *grid = gtk_grid_new();

    gtk_grid_set_row_spacing(GTK_GRID(grid), 12);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 20);
    gtk_widget_set_hexpand(grid, TRUE);
    return grid;
}

void bubble_settings_add_row(GtkGrid *grid, gint row, const gchar *label_text,
                             GtkWidget *widget)
{
    GtkWidget *label = gtk_label_new(label_text);

    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_widget_set_valign(label, GTK_ALIGN_CENTER);
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_style_context_add_class(gtk_widget_get_style_context(label),
                                "row-label");
    gtk_widget_set_hexpand(widget, TRUE);
    gtk_grid_attach(grid, label, 0, row, 1, 1);
    gtk_grid_attach(grid, widget, 1, row, 1, 1);
}

GtkWidget *bubble_settings_add_switch(GtkGrid *grid, gint row,
                                      const gchar *label, gboolean active)
{
    GtkWidget *widget = gtk_switch_new();

    gtk_switch_set_active(GTK_SWITCH(widget), active);
    gtk_widget_set_halign(widget, GTK_ALIGN_START);
    gtk_widget_set_hexpand(widget, FALSE);
    bubble_settings_add_row(grid, row, label, widget);
    return widget;
}

GtkWidget *bubble_settings_add_spin(GtkGrid *grid, gint row, const gchar *label,
                                    gdouble min, gdouble max, gdouble step,
                                    gdouble value)
{
    GtkWidget *widget = gtk_spin_button_new_with_range(min, max, step);

    gtk_spin_button_set_value(GTK_SPIN_BUTTON(widget), value);
    gtk_widget_set_halign(widget, GTK_ALIGN_START);
    gtk_widget_set_hexpand(widget, FALSE);
    bubble_settings_add_row(grid, row, label, widget);
    return widget;
}

GtkWidget *bubble_settings_add_combo(GtkGrid *grid, gint row, const gchar *label,
                                     const gchar *current, gchar **choices)
{
    GtkWidget *widget = gtk_combo_box_text_new();
    gboolean found = FALSE;

    for (guint i = 0; choices != NULL && choices[i] != NULL; i++) {
        if (current != NULL && g_strcmp0(choices[i], current) == 0) {
            found = TRUE;
        }
        gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(widget), choices[i],
                                  choices[i]);
    }
    if (!found && current != NULL && *current != '\0') {
        gtk_combo_box_text_prepend(GTK_COMBO_BOX_TEXT(widget), current,
                                   current);
    }
    if (current != NULL && *current != '\0') {
        gtk_combo_box_set_active_id(GTK_COMBO_BOX(widget), current);
    }
    if (gtk_combo_box_get_active(GTK_COMBO_BOX(widget)) < 0) {
        gtk_combo_box_set_active(GTK_COMBO_BOX(widget), 0);
    }
    gtk_widget_set_halign(widget, GTK_ALIGN_FILL);
    bubble_settings_add_row(grid, row, label, widget);
    return widget;
}

GtkWidget *bubble_settings_add_entry(GtkGrid *grid, gint row, const gchar *label,
                                     const gchar *value)
{
    GtkWidget *widget = gtk_entry_new();

    gtk_entry_set_text(GTK_ENTRY(widget), value != NULL ? value : "");
    gtk_widget_set_halign(widget, GTK_ALIGN_FILL);
    bubble_settings_add_row(grid, row, label, widget);
    return widget;
}

void bubble_settings_add_apply(GtkWidget *page, GCallback cb, gpointer data)
{
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *button = gtk_button_new_with_label("Appliquer");

    gtk_widget_set_halign(row, GTK_ALIGN_END);
    gtk_style_context_add_class(gtk_widget_get_style_context(button),
                                "suggested-action");
    g_signal_connect(button, "clicked", cb, data);
    gtk_box_pack_start(GTK_BOX(row), button, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), row, FALSE, FALSE, 0);
}

gchar *bubble_settings_combo_text(GtkWidget *combo)
{
    gchar *text = gtk_combo_box_text_get_active_text(GTK_COMBO_BOX_TEXT(combo));
    return text != NULL ? text : g_strdup("");
}

static gboolean write_gtk_settings(const gchar *theme, const gchar *icons,
                                   const gchar *cursor, gint cursor_size,
                                   const gchar *font)
{
    const gchar *versions[] = {"3.0", "4.0", NULL};
    gboolean ok = TRUE;

    for (guint i = 0; versions[i] != NULL; i++) {
        gchar *dir = g_build_filename(g_get_user_config_dir(), "gtk-3.0", NULL);
        gchar *path;
        gchar *contents;
        GError *error = NULL;

        if (i == 1) {
            g_free(dir);
            dir = g_build_filename(g_get_user_config_dir(), "gtk-4.0", NULL);
        }
        if (g_mkdir_with_parents(dir, 0700) != 0) {
            g_free(dir);
            ok = FALSE;
            continue;
        }
        path = g_build_filename(dir, "settings.ini", NULL);
        contents = g_strdup_printf(
            "[Settings]\n"
            "gtk-theme-name=%s\n"
            "gtk-icon-theme-name=%s\n"
            "gtk-cursor-theme-name=%s\n"
            "gtk-cursor-theme-size=%d\n"
            "gtk-font-name=%s\n"
            "gtk-application-prefer-dark-theme=1\n",
            theme, icons, cursor, cursor_size, font);
        if (!g_file_set_contents(path, contents, -1, &error)) {
            g_clear_error(&error);
            ok = FALSE;
        } else {
            g_chmod(path, 0600);
        }
        g_free(contents);
        g_free(path);
        g_free(dir);
    }
    return ok;
}

static void appearance_apply(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *theme = bubble_settings_combo_text(s->theme_combo);
    gchar *icons = bubble_settings_combo_text(s->icons_combo);
    gchar *cursor = bubble_settings_combo_text(s->cursor_combo);
    gchar *family = bubble_settings_combo_text(s->font_combo);
    gint cursor_size = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(s->cursor_size_spin));
    gint font_size = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(s->font_size_spin));
    gchar *font = g_strdup_printf("%s %d", family, font_size);
    gboolean ok;

    (void)button;

    if (*theme == '\0' || *icons == '\0' || *cursor == '\0' || *family == '\0') {
        bubble_settings_error(s, "Tous les champs d’apparence sont requis.");
        goto out;
    }

    ok = bubble_settings_config_set(s, "DESKTOP_GTK_THEME", theme) &&
         bubble_settings_config_set(s, "DESKTOP_ICON_THEME", icons) &&
         bubble_settings_config_set(s, "DESKTOP_CURSOR_THEME", cursor) &&
         config_set_int(s, "DESKTOP_CURSOR_SIZE", cursor_size) &&
         bubble_settings_config_set(s, "DESKTOP_FONT", font);
    if (ok) {
        ok = write_gtk_settings(theme, icons, cursor, cursor_size, font);
    }
    if (ok) {
        ok = bubble_settings_apply(s);
    }
    if (ok) {
        bubble_settings_status(s, "Apparence enregistrée et appliquée.");
    }

out:
    g_free(theme);
    g_free(icons);
    g_free(cursor);
    g_free(family);
    g_free(font);
}

GtkWidget *bubble_settings_appearance_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "Apparence", "Thème, icônes, curseur et police du bureau bubbleOS.");
    GtkWidget *card = bubble_settings_card("Thème et typographie");
    GtkWidget *grid = bubble_settings_grid();
    GPtrArray *themes = list_entries("/usr/share/themes", "gtk-3.0", TRUE);
    GPtrArray *icons = list_entries("/usr/share/icons", "index.theme", FALSE);
    GPtrArray *cursors = list_entries("/usr/share/icons", "cursors", TRUE);
    GPtrArray *fonts = list_font_families();
    gchar **theme_choices;
    gchar **icon_choices;
    gchar **cursor_choices;
    gchar **font_choices;
    gchar *font_family;
    gchar *font_value = g_strdup(bubble_settings_config(s, "DESKTOP_FONT"));

    if (themes->len == 0) {
        g_ptr_array_add(themes, g_strdup("Adwaita-dark"));
    }
    if (icons->len == 0) {
        g_ptr_array_add(icons, g_strdup("Papirus-Dark"));
    }
    if (cursors->len == 0) {
        g_ptr_array_add(cursors, g_strdup("Bibata-Modern-Ice"));
    }

    theme_choices = ptr_array_to_strv(themes);
    icon_choices = ptr_array_to_strv(icons);
    cursor_choices = ptr_array_to_strv(cursors);
    font_choices = ptr_array_to_strv(fonts);
    font_family = font_family_from_value(font_value);

    s->theme_combo = bubble_settings_add_combo(
        GTK_GRID(grid), 0, "Thème GTK", bubble_settings_config(s, "DESKTOP_GTK_THEME"),
        theme_choices);
    s->icons_combo = bubble_settings_add_combo(
        GTK_GRID(grid), 1, "Jeu d’icônes",
        bubble_settings_config(s, "DESKTOP_ICON_THEME"), icon_choices);
    s->cursor_combo = bubble_settings_add_combo(
        GTK_GRID(grid), 2, "Curseur", bubble_settings_config(s, "DESKTOP_CURSOR_THEME"),
        cursor_choices);
    s->cursor_size_spin = bubble_settings_add_spin(
        GTK_GRID(grid), 3, "Taille du curseur", 16, 64, 1,
        atoi(bubble_settings_config(s, "DESKTOP_CURSOR_SIZE")));
    s->font_combo = bubble_settings_add_combo(
        GTK_GRID(grid), 4, "Police", font_family, font_choices);
    s->font_size_spin = bubble_settings_add_spin(
        GTK_GRID(grid), 5, "Taille de police", 6, 32, 1,
        font_size_from_value(font_value));

    gtk_box_pack_start(GTK_BOX(card), grid, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);
    bubble_settings_add_apply(page, G_CALLBACK(appearance_apply), s);

    g_strfreev(theme_choices);
    g_strfreev(icon_choices);
    g_strfreev(cursor_choices);
    g_strfreev(font_choices);
    g_free(font_family);
    g_free(font_value);
    return page;
}

static void update_wallpaper_preview(BubbleSettings *s)
{
    GdkPixbuf *pixbuf = NULL;

    if (s->wallpaper_path != NULL && *s->wallpaper_path != '\0') {
        pixbuf = gdk_pixbuf_new_from_file_at_scale(s->wallpaper_path, 480,
                                                   270, TRUE, NULL);
    }
    if (pixbuf != NULL) {
        gtk_image_set_from_pixbuf(GTK_IMAGE(s->wallpaper_preview), pixbuf);
        g_object_unref(pixbuf);
    } else {
        gtk_image_set_from_icon_name(GTK_IMAGE(s->wallpaper_preview),
                                     "image-missing", GTK_ICON_SIZE_DIALOG);
    }
    if (s->wallpaper_label != NULL) {
        gtk_label_set_text(GTK_LABEL(s->wallpaper_label),
                           s->wallpaper_path != NULL ? s->wallpaper_path : "");
    }
}

static void wallpaper_choose(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    GtkWidget *dialog;
    GtkFileFilter *filter;

    (void)button;

    dialog = gtk_file_chooser_dialog_new(
        "Choisir un fond d’écran", GTK_WINDOW(s->window),
        GTK_FILE_CHOOSER_ACTION_OPEN, "Annuler", GTK_RESPONSE_CANCEL,
        "Choisir", GTK_RESPONSE_ACCEPT, NULL);
    filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Images");
    gtk_file_filter_add_pattern(filter, "*.png");
    gtk_file_filter_add_pattern(filter, "*.jpg");
    gtk_file_filter_add_pattern(filter, "*.jpeg");
    gtk_file_filter_add_pattern(filter, "*.webp");
    gtk_file_filter_add_pattern(filter, "*.bmp");
    gtk_file_filter_add_pattern(filter, "*.svg");
    gtk_file_chooser_add_filter(GTK_FILE_CHOOSER(dialog), filter);

    if (s->wallpaper_path != NULL && *s->wallpaper_path != '\0') {
        gchar *dirname = g_path_get_dirname(s->wallpaper_path);
        if (g_file_test(dirname, G_FILE_TEST_IS_DIR)) {
            gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog),
                                                dirname);
        }
        g_free(dirname);
    }
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        gchar *filename = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
        g_free(s->wallpaper_path);
        s->wallpaper_path = filename;
        update_wallpaper_preview(s);
    }
    gtk_widget_destroy(dialog);
}

static void wallpaper_apply(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    const gchar *mode =
        gtk_combo_box_get_active_id(GTK_COMBO_BOX(s->wallpaper_mode));
    gboolean enabled = gtk_switch_get_active(GTK_SWITCH(s->wallpaper_enabled));
    gboolean ok;

    (void)button;

    if (s->wallpaper_path == NULL || *s->wallpaper_path == '\0') {
        bubble_settings_error(s, "Choisissez d’abord un fichier image.");
        return;
    }
    if (mode == NULL || *mode == '\0') {
        bubble_settings_error(s, "Choisissez un mode d’affichage.");
        return;
    }

    ok = bubble_settings_config_set(s, "DESKTOP_WALLPAPER",
                                    enabled ? "1" : "0") &&
         bubble_settings_config_set(s, "DESKTOP_WALLPAPER_FILE",
                                    s->wallpaper_path) &&
         bubble_settings_config_set(s, "DESKTOP_WALLPAPER_MODE", mode);
    if (ok) {
        ok = bubble_settings_apply(s);
    }
    if (ok) {
        bubble_settings_status(s, "Fond d’écran appliqué.");
    }
}

GtkWidget *bubble_settings_wallpaper_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "Fond d’écran", "Image de bureau et mode de mise à l’échelle.");
    GtkWidget *card = bubble_settings_card("Image de bureau");
    GtkWidget *grid = bubble_settings_grid();
    GtkWidget *preview_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    GtkWidget *choose = gtk_button_new_with_label("Choisir une image…");

    s->wallpaper_path =
        g_strdup(bubble_settings_config(s, "DESKTOP_WALLPAPER_FILE"));
    s->wallpaper_enabled = bubble_settings_add_switch(
        GTK_GRID(grid), 0, "Activer le fond d’écran",
        g_strcmp0(bubble_settings_config(s, "DESKTOP_WALLPAPER"), "1") == 0);

    s->wallpaper_preview = gtk_image_new();
    gtk_widget_set_size_request(s->wallpaper_preview, 480, 270);
    gtk_widget_set_halign(s->wallpaper_preview, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(s->wallpaper_preview),
                                "wallpaper-preview");
    s->wallpaper_label = gtk_label_new("");
    gtk_label_set_ellipsize(GTK_LABEL(s->wallpaper_label), PANGO_ELLIPSIZE_MIDDLE);
    gtk_label_set_max_width_chars(GTK_LABEL(s->wallpaper_label), 60);
    gtk_widget_set_halign(s->wallpaper_label, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(s->wallpaper_label),
                                "path-label");
    g_signal_connect(choose, "clicked", G_CALLBACK(wallpaper_choose), s);
    gtk_box_pack_start(GTK_BOX(preview_box), s->wallpaper_preview, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(preview_box), s->wallpaper_label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(preview_box), choose, FALSE, FALSE, 0);
    bubble_settings_add_row(GTK_GRID(grid), 1, "Aperçu", preview_box);

    s->wallpaper_mode = gtk_combo_box_text_new();
    gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(s->wallpaper_mode), "fill",
                              "Remplir l’écran");
    gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(s->wallpaper_mode), "fit",
                              "Ajuster");
    gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(s->wallpaper_mode), "stretch",
                              "Étirer");
    gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(s->wallpaper_mode), "center",
                              "Centrer");
    gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(s->wallpaper_mode), "tile",
                              "Mosaïque");
    gtk_combo_box_set_active_id(
        GTK_COMBO_BOX(s->wallpaper_mode),
        bubble_settings_config(s, "DESKTOP_WALLPAPER_MODE"));
    if (gtk_combo_box_get_active(GTK_COMBO_BOX(s->wallpaper_mode)) < 0) {
        gtk_combo_box_set_active(GTK_COMBO_BOX(s->wallpaper_mode), 0);
    }
    bubble_settings_add_row(GTK_GRID(grid), 2, "Mode", s->wallpaper_mode);

    update_wallpaper_preview(s);
    gtk_box_pack_start(GTK_BOX(card), grid, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);
    bubble_settings_add_apply(page, G_CALLBACK(wallpaper_apply), s);
    return page;
}

static gboolean valid_module_list(const gchar *value)
{
    gchar **items = g_strsplit_set(value != NULL ? value : "", " ,", -1);
    gboolean ok = TRUE;

    for (guint i = 0; items[i] != NULL; i++) {
        if (*items[i] == '\0') {
            continue;
        }
        if (!g_regex_match_simple("^[A-Za-z0-9._/-]+$", items[i], 0, 0)) {
            ok = FALSE;
            break;
        }
    }
    g_strfreev(items);
    return ok;
}

static void bar_apply(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    const gchar *left = gtk_entry_get_text(GTK_ENTRY(s->bar_left));
    const gchar *center = gtk_entry_get_text(GTK_ENTRY(s->bar_center));
    const gchar *right = gtk_entry_get_text(GTK_ENTRY(s->bar_right));
    gchar *position = bubble_settings_combo_text(s->bar_position);
    gboolean enabled = gtk_switch_get_active(GTK_SWITCH(s->bar_enabled));
    gint height = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(s->bar_height));
    gboolean ok;

    (void)button;

    if (!valid_module_list(left) || !valid_module_list(center) ||
        !valid_module_list(right)) {
        bubble_settings_error(
            s, "Les modules Waybar ne peuvent contenir que des lettres, "
               "chiffres, points, tirets, slashs et underscores.");
        goto out;
    }

    ok = bubble_settings_config_set(s, "DESKTOP_WAYBAR", enabled ? "1" : "0") &&
         bubble_settings_config_set(s, "DESKTOP_WAYBAR_POSITION", position) &&
         config_set_int(s, "DESKTOP_WAYBAR_HEIGHT", height) &&
         bubble_settings_config_set(s, "DESKTOP_WAYBAR_LEFT", left) &&
         bubble_settings_config_set(s, "DESKTOP_WAYBAR_CENTER", center) &&
         bubble_settings_config_set(s, "DESKTOP_WAYBAR_RIGHT", right);
    if (ok) {
        ok = bubble_settings_apply(s);
    }
    if (ok) {
        bubble_settings_status(s, "Barre Waybar appliquée.");
    }

out:
    g_free(position);
}

GtkWidget *bubble_settings_bar_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "Barre & notifications",
        "Position, taille et modules de Waybar. Mako affiche les notifications.");
    GtkWidget *card = bubble_settings_card("Waybar");
    GtkWidget *grid = bubble_settings_grid();
    gchar **positions = g_strsplit("top bottom", " ", -1);

    s->bar_enabled = bubble_settings_add_switch(
        GTK_GRID(grid), 0, "Afficher la barre",
        g_strcmp0(bubble_settings_config(s, "DESKTOP_WAYBAR"), "1") == 0);
    s->bar_position = bubble_settings_add_combo(
        GTK_GRID(grid), 1, "Position",
        bubble_settings_config(s, "DESKTOP_WAYBAR_POSITION"), positions);
    s->bar_height = bubble_settings_add_spin(
        GTK_GRID(grid), 2, "Hauteur", 20, 100, 1,
        atoi(bubble_settings_config(s, "DESKTOP_WAYBAR_HEIGHT")));
    s->bar_left = bubble_settings_add_entry(
        GTK_GRID(grid), 3, "Modules à gauche",
        bubble_settings_config(s, "DESKTOP_WAYBAR_LEFT"));
    s->bar_center = bubble_settings_add_entry(
        GTK_GRID(grid), 4, "Modules au centre",
        bubble_settings_config(s, "DESKTOP_WAYBAR_CENTER"));
    s->bar_right = bubble_settings_add_entry(
        GTK_GRID(grid), 5, "Modules à droite",
        bubble_settings_config(s, "DESKTOP_WAYBAR_RIGHT"));
    gtk_box_pack_start(GTK_BOX(card), grid, FALSE, FALSE, 0);

    GtkWidget *hint = gtk_label_new(
        "Modules disponibles : custom/logo, network, bluetooth, clock, "
        "battery, pulseaudio, tray, custom/power. Séparez-les par des espaces.");
    gtk_label_set_line_wrap(GTK_LABEL(hint), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(hint), 80);
    gtk_widget_set_halign(hint, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(hint), "hint");
    gtk_box_pack_start(GTK_BOX(card), hint, FALSE, FALSE, 0);

    gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);
    bubble_settings_add_apply(page, G_CALLBACK(bar_apply), s);
    g_strfreev(positions);
    return page;
}

static void choose_screenshot_dir(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        "Dossier des captures", GTK_WINDOW(s->window),
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, "Annuler", GTK_RESPONSE_CANCEL,
        "Choisir", GTK_RESPONSE_ACCEPT, NULL);
    const gchar *current = gtk_entry_get_text(GTK_ENTRY(s->session_screenshot));

    (void)button;

    if (*current != '\0' && g_file_test(current, G_FILE_TEST_IS_DIR)) {
        gtk_file_chooser_set_current_folder(GTK_FILE_CHOOSER(dialog), current);
    }
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        gchar *folder = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
        gtk_entry_set_text(GTK_ENTRY(s->session_screenshot), folder);
        g_free(folder);
    }
    gtk_widget_destroy(dialog);
}

static void session_apply(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    const gchar *terminal = gtk_entry_get_text(GTK_ENTRY(s->session_terminal));
    const gchar *launcher = gtk_entry_get_text(GTK_ENTRY(s->session_launcher));
    const gchar *screenshots =
        gtk_entry_get_text(GTK_ENTRY(s->session_screenshot));
    gboolean mako = gtk_switch_get_active(GTK_SWITCH(s->session_mako));
    gboolean idle = gtk_switch_get_active(GTK_SWITCH(s->session_idle));
    gint dpms = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(s->session_dpms));
    gint lock = gtk_spin_button_get_value_as_int(GTK_SPIN_BUTTON(s->session_lock));
    gboolean ok;

    (void)button;

    if (*terminal == '\0' || *launcher == '\0') {
        bubble_settings_error(s, "Le terminal et le lanceur doivent être renseignés.");
        return;
    }

    ok = bubble_settings_config_set(s, "DESKTOP_TERMINAL", terminal) &&
         bubble_settings_config_set(s, "DESKTOP_LAUNCHER", launcher) &&
         bubble_settings_config_set(s, "DESKTOP_SCREENSHOT_DIR", screenshots) &&
         bubble_settings_config_set(s, "DESKTOP_MAKO", mako ? "1" : "0") &&
         bubble_settings_config_set(s, "DESKTOP_IDLE", idle ? "1" : "0") &&
         config_set_int(s, "DESKTOP_IDLE_DPMS", dpms) &&
         config_set_int(s, "DESKTOP_IDLE_LOCK", lock);
    if (ok) {
        ok = bubble_settings_apply(s);
    }
    if (ok) {
        bubble_settings_status(s, "Réglages de session appliqués.");
    }
}

GtkWidget *bubble_settings_session_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "Session", "Terminal, lanceur, notifications et verrouillage automatique.");
    GtkWidget *card = bubble_settings_card("Applications et session");
    GtkWidget *grid = bubble_settings_grid();
    GtkWidget *browse = gtk_button_new_with_label("Parcourir…");

    s->session_terminal = bubble_settings_add_entry(
        GTK_GRID(grid), 0, "Terminal", bubble_settings_config(s, "DESKTOP_TERMINAL"));
    s->session_launcher = bubble_settings_add_entry(
        GTK_GRID(grid), 1, "Lanceur", bubble_settings_config(s, "DESKTOP_LAUNCHER"));
    s->session_screenshot = bubble_settings_add_entry(
        GTK_GRID(grid), 2, "Captures d’écran",
        bubble_settings_config(s, "DESKTOP_SCREENSHOT_DIR"));
    g_signal_connect(browse, "clicked", G_CALLBACK(choose_screenshot_dir), s);
    bubble_settings_add_row(GTK_GRID(grid), 3, "", browse);
    s->session_mako = bubble_settings_add_switch(
        GTK_GRID(grid), 4, "Notifications Mako",
        g_strcmp0(bubble_settings_config(s, "DESKTOP_MAKO"), "1") == 0);
    s->session_idle = bubble_settings_add_switch(
        GTK_GRID(grid), 5, "Verrouillage automatique",
        g_strcmp0(bubble_settings_config(s, "DESKTOP_IDLE"), "1") == 0);
    s->session_dpms = bubble_settings_add_spin(
        GTK_GRID(grid), 6, "Extinction de l’écran (s)", 0, 7200, 30,
        atoi(bubble_settings_config(s, "DESKTOP_IDLE_DPMS")));
    s->session_lock = bubble_settings_add_spin(
        GTK_GRID(grid), 7, "Verrouillage (s)", 0, 7200, 30,
        atoi(bubble_settings_config(s, "DESKTOP_IDLE_LOCK")));

    gtk_box_pack_start(GTK_BOX(card), grid, FALSE, FALSE, 0);
    GtkWidget *hint = gtk_label_new(
        "0 désactive l’action correspondante. Les valeurs sont en secondes.");
    gtk_widget_set_halign(hint, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(hint), "hint");
    gtk_box_pack_start(GTK_BOX(card), hint, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);
    bubble_settings_add_apply(page, G_CALLBACK(session_apply), s);
    return page;
}

static GtkWidget *status_value_label(const gchar *text)
{
    GtkWidget *label = gtk_label_new(text != NULL ? text : "");
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_label_set_xalign(GTK_LABEL(label), 0.0f);
    gtk_label_set_selectable(GTK_LABEL(label), TRUE);
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_style_context_add_class(gtk_widget_get_style_context(label),
                                "about-value");
    return label;
}

static gchar *run_capture(const gchar *const *argv)
{
    gchar *out = NULL;
    gchar *err = NULL;
    gint status = 0;

    if (!g_spawn_sync(NULL, (gchar **)argv, NULL, G_SPAWN_SEARCH_PATH, NULL,
                      NULL, &out, &err, &status, NULL) ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        g_free(out);
        g_free(err);
        return NULL;
    }
    g_free(err);
    g_strchomp(out);
    return out;
}

static void launch_program(BubbleSettings *s, const gchar *program,
                           gchar **argv)
{
    GError *error = NULL;

    (void)program;
    if (!g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL,
                       &error)) {
        bubble_settings_error(s, "Impossible de lancer %s.\n%s", argv[0],
                              error != NULL ? error->message : "");
        g_clear_error(&error);
    }
}

static void open_wcm(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *argv[] = {"wcm", NULL};
    (void)button;
    launch_program(s, "wcm", argv);
}

static void open_network(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *argv[] = {"nm-connection-editor", NULL};
    (void)button;
    launch_program(s, "nm-connection-editor", argv);
}

static void open_sound(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *argv[] = {"pavucontrol", NULL};
    (void)button;
    launch_program(s, "pavucontrol", argv);
}

static void open_bluetooth(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *argv[] = {"bubble-desktop", "bluetooth", NULL};
    (void)button;
    launch_program(s, "bubble-desktop", argv);
}

static void open_display(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *argv[] = {"foot", "-e", "sh", "-c",
                     "wlr-randr; printf '\\nAppuyez sur Entrée…'; read -r _",
                     NULL};
    (void)button;
    launch_program(s, "foot", argv);
}

static void open_power(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *argv[] = {"foot", "-e", "sh", "-c",
                     "upower -d; printf '\\nAppuyez sur Entrée…'; read -r _",
                     NULL};
    (void)button;
    launch_program(s, "foot", argv);
}

static GtkWidget *system_card(const gchar *title, const gchar *description,
                              const gchar *button_label, GCallback callback,
                              gpointer data)
{
    GtkWidget *card = bubble_settings_card(title);
    GtkWidget *label = gtk_label_new(description);
    GtkWidget *button = gtk_button_new_with_label(button_label);
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);

    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 80);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(label),
                                "row-label");
    gtk_widget_set_halign(row, GTK_ALIGN_END);
    g_signal_connect(button, "clicked", callback, data);
    gtk_box_pack_start(GTK_BOX(row), button, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(card), label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(card), row, FALSE, FALSE, 0);
    return card;
}

GtkWidget *bubble_settings_system_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "Système",
        "Les réglages spécialisés ouvrent l’outil officiel correspondant.");
    GtkWidget *network = system_card(
        "Réseau", "Connexions filaires, Wi-Fi, VPN et profils NetworkManager.",
        "Ouvrir l’éditeur de connexions", G_CALLBACK(open_network), s);
    GtkWidget *bluetooth = system_card(
        "Bluetooth", "Appairer et gérer les appareils Bluetooth.",
        "Ouvrir Bluetooth", G_CALLBACK(open_bluetooth), s);
    GtkWidget *sound = system_card(
        "Son", "Périphériques, volume, routage et profils PipeWire.",
        "Ouvrir le contrôleur audio", G_CALLBACK(open_sound), s);
    GtkWidget *display = system_card(
        "Affichage", "Résolutions, fréquences, échelle et sorties Wayland.",
        "Afficher les écrans", G_CALLBACK(open_display), s);
    GtkWidget *power = system_card(
        "Énergie", "Batterie, alimentation et état des périphériques.",
        "Afficher l’état d’alimentation", G_CALLBACK(open_power), s);
    GtkWidget *wayfire = system_card(
        "Wayfire & clavier",
        "Raccourcis, disposition du clavier, effets et décoration des fenêtres.",
        "Ouvrir la configuration Wayfire", G_CALLBACK(open_wcm), s);

    gtk_box_pack_start(GTK_BOX(page), network, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), bluetooth, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), sound, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), display, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), power, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), wayfire, FALSE, FALSE, 0);
    return page;
}

static GPtrArray *list_timezones(void)
{
    GPtrArray *items = g_ptr_array_new_with_free_func(g_free);
    gchar *contents = NULL;

    if (g_file_get_contents("/usr/share/zoneinfo/zone.tab", &contents, NULL,
                            NULL)) {
        gchar **lines = g_strsplit(contents, "\n", -1);
        for (guint i = 0; lines[i] != NULL; i++) {
            if (lines[i][0] == '#' || *lines[i] == '\0') {
                continue;
            }
            gchar **fields = g_strsplit(lines[i], "\t", -1);
            if (fields[2] != NULL && *fields[2] != '\0') {
                g_ptr_array_add(items, g_strdup(fields[2]));
            }
            g_strfreev(fields);
        }
        g_strfreev(lines);
    }
    g_free(contents);
    g_ptr_array_sort(items, compare_strings);
    return items;
}

static void datetime_apply(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    gchar *timezone = bubble_settings_combo_text(s->timezone_combo);
    gboolean ntp = gtk_switch_get_active(GTK_SWITCH(s->ntp_switch));
    gchar *tz_argv[] = {"pkexec", "/usr/bin/timedatectl", "set-timezone",
                        timezone, NULL};
    gchar *ntp_argv[] = {"pkexec", "/usr/bin/timedatectl", "set-ntp",
                         ntp ? "true" : "false", NULL};
    gchar *out = NULL;
    gchar *err = NULL;

    (void)button;

    if (*timezone == '\0') {
        bubble_settings_error(s, "Choisissez un fuseau horaire.");
        g_free(timezone);
        return;
    }
    if (!bubble_settings_run(s, tz_argv, NULL, &out, &err)) {
        bubble_settings_error(s, "Impossible de changer le fuseau horaire.\n%s",
                              err != NULL ? err : "");
        goto out;
    }
    g_free(out);
    g_free(err);
    out = NULL;
    err = NULL;
    if (!bubble_settings_run(s, ntp_argv, NULL, &out, &err)) {
        bubble_settings_error(s, "Impossible de changer la synchronisation NTP.\n%s",
                              err != NULL ? err : "");
        goto out;
    }
    bubble_settings_status(s, "Date et heure mises à jour.");

out:
    g_free(out);
    g_free(err);
    g_free(timezone);
}

GtkWidget *bubble_settings_datetime_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "Date & heure", "Fuseau horaire et synchronisation réseau (NTP).");
    GtkWidget *card = bubble_settings_card("Horloge système");
    GtkWidget *grid = bubble_settings_grid();
    GPtrArray *zones = list_timezones();
    gchar **choices;
    gchar *current_tz = run_capture((const gchar *const[]){"timedatectl",
                                                           "show", "-p",
                                                           "Timezone", "--value",
                                                           NULL});
    gchar *ntp_value = run_capture((const gchar *const[]){"timedatectl",
                                                           "show", "-p", "NTP",
                                                           "--value", NULL});
    gchar *now = run_capture((const gchar *const[]){"date",
                                                     "+%A %d %B %Y, %H:%M",
                                                     NULL});
    const gchar *tz = current_tz != NULL ? current_tz : "UTC";

    if (zones->len == 0) {
        g_ptr_array_add(zones, g_strdup("UTC"));
    }
    choices = ptr_array_to_strv(zones);
    s->timezone_combo = bubble_settings_add_combo(
        GTK_GRID(grid), 0, "Fuseau horaire", tz, choices);
    s->ntp_switch = bubble_settings_add_switch(
        GTK_GRID(grid), 1, "Synchronisation NTP",
        g_strcmp0(ntp_value, "yes") == 0);
    s->time_label = status_value_label(now != NULL ? now : "Horloge indisponible");
    bubble_settings_add_row(GTK_GRID(grid), 2, "Date et heure", s->time_label);

    gtk_box_pack_start(GTK_BOX(card), grid, FALSE, FALSE, 0);
    GtkWidget *hint = gtk_label_new(
        "Modifier l’heure ou le fuseau demande l’authentification d’un administrateur.");
    gtk_widget_set_halign(hint, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(hint), "hint");
    gtk_box_pack_start(GTK_BOX(card), hint, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);
    bubble_settings_add_apply(page, G_CALLBACK(datetime_apply), s);

    g_strfreev(choices);
    g_free(current_tz);
    g_free(ntp_value);
    g_free(now);
    return page;
}

static gchar *os_release_value(const gchar *key)
{
    gchar *contents = NULL;
    gchar *value = NULL;

    if (!g_file_get_contents("/etc/os-release", &contents, NULL, NULL)) {
        return g_strdup("bubbleOS");
    }
    gchar **lines = g_strsplit(contents, "\n", -1);
    gsize key_len = strlen(key);
    for (guint i = 0; lines[i] != NULL; i++) {
        if (g_str_has_prefix(lines[i], key) && lines[i][key_len] == '=') {
            value = g_strdup(lines[i] + key_len + 1);
            g_strdelimit(value, "\"", '\0');
            break;
        }
    }
    g_strfreev(lines);
    g_free(contents);
    return value != NULL ? value : g_strdup("bubbleOS");
}

GtkWidget *bubble_settings_about_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "À propos", "Informations sur cette installation de bubbleOS.");
    GtkWidget *card = bubble_settings_card("bubbleOS");
    GtkWidget *grid = bubble_settings_grid();
    gchar *pretty = os_release_value("PRETTY_NAME");
    struct utsname uname_buf;
    const gchar *kernel = "inconnu";
    gchar *generation = run_capture(
        (const gchar *const[]){"bubble", "generation", "current", NULL});
    gchar *uptime = run_capture((const gchar *const[]){"uptime", "-p", NULL});
    gchar *gtk_version = g_strdup_printf("%d.%d.%d", gtk_get_major_version(),
                                         gtk_get_minor_version(),
                                         gtk_get_micro_version());

    if (uname(&uname_buf) == 0) {
        kernel = uname_buf.release;
    }

    bubble_settings_add_row(GTK_GRID(grid), 0, "Version",
                            status_value_label(pretty));
    bubble_settings_add_row(GTK_GRID(grid), 1, "Noyau",
                            status_value_label(kernel));
    bubble_settings_add_row(GTK_GRID(grid), 2, "Génération active",
                            status_value_label(generation != NULL ? generation
                                                                   : "inconnue"));
    bubble_settings_add_row(GTK_GRID(grid), 3, "Démarré depuis",
                            status_value_label(uptime != NULL ? uptime
                                                              : "inconnu"));
    bubble_settings_add_row(GTK_GRID(grid), 4, "GTK",
                            status_value_label(gtk_version));
    bubble_settings_add_row(GTK_GRID(grid), 5, "Paramètres",
                            status_value_label("bubble-settings "
                                               BUBBLE_SETTINGS_VERSION));

    gtk_box_pack_start(GTK_BOX(card), grid, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);

    GtkWidget *hint = gtk_label_new(
        "bubbleOS est composé de générations Btrfs atomiques. Utilisez "
        "« bubble generation » pour créer, activer ou revenir à une génération.");
    gtk_label_set_line_wrap(GTK_LABEL(hint), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(hint), 80);
    gtk_widget_set_halign(hint, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(hint), "hint");
    gtk_box_pack_start(GTK_BOX(page), hint, FALSE, FALSE, 0);

    g_free(pretty);
    g_free(generation);
    g_free(uptime);
    g_free(gtk_version);
    return page;
}
