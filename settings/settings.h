#pragma once

#include <gtk/gtk.h>
#include <sys/types.h>

#define BUBBLE_SETTINGS_VERSION "0.1.0"

#ifndef BUBBLE_SETTINGS_HELPER
#define BUBBLE_SETTINGS_HELPER "/usr/libexec/bubbleos/bubble-settings-helper"
#endif

#ifndef BUBBLE_SETTINGS_CSS
#define BUBBLE_SETTINGS_CSS "/usr/share/bubbleos/settings/bubble-settings.css"
#endif

typedef struct {
    gchar *name;
    gchar *gecos;
    uid_t uid;
    gid_t gid;
    gchar *home;
    gchar *shell;
    gboolean admin;
} BubbleUser;

typedef struct {
    GtkApplication *app;
    GtkWidget *window;
    GtkWidget *stack;
    GtkWidget *sidebar;
    GtkWidget *search;
    GtkWidget *status;
    guint status_timeout;
    GHashTable *config;
    gchar *initial_page;
    gboolean smoke_test;

    GtkWidget *theme_combo;
    GtkWidget *icons_combo;
    GtkWidget *cursor_combo;
    GtkWidget *cursor_size_spin;
    GtkWidget *font_combo;
    GtkWidget *font_size_spin;

    GtkWidget *wallpaper_enabled;
    GtkWidget *wallpaper_preview;
    GtkWidget *wallpaper_label;
    GtkWidget *wallpaper_mode;
    gchar *wallpaper_path;

    GtkWidget *bar_enabled;
    GtkWidget *bar_position;
    GtkWidget *bar_height;
    GtkWidget *bar_left;
    GtkWidget *bar_center;
    GtkWidget *bar_right;

    GtkWidget *session_terminal;
    GtkWidget *session_launcher;
    GtkWidget *session_screenshot;
    GtkWidget *session_mako;
    GtkWidget *session_idle;
    GtkWidget *session_dpms;
    GtkWidget *session_lock;

    GtkWidget *timezone_combo;
    GtkWidget *ntp_switch;
    GtkWidget *time_label;

    GtkWidget *users_list;
    GtkWidget *users_password;
    GtkWidget *users_delete;
    GtkWidget *users_info;
    GPtrArray *users;
} BubbleSettings;

BubbleSettings *bubble_settings_new(GtkApplication *app);
void bubble_settings_build_window(BubbleSettings *s);
void bubble_settings_select_page(BubbleSettings *s, const gchar *page);
void bubble_settings_status(BubbleSettings *s, const gchar *text);
void bubble_settings_error(BubbleSettings *s, const gchar *fmt, ...) G_GNUC_PRINTF(2, 3);
void bubble_settings_info(BubbleSettings *s, const gchar *fmt, ...) G_GNUC_PRINTF(2, 3);

gboolean bubble_settings_run(BubbleSettings *s, gchar **argv, const gchar *input,
                             gchar **out, gchar **err);
const gchar *bubble_settings_config(BubbleSettings *s, const gchar *key);
gboolean bubble_settings_config_set(BubbleSettings *s, const gchar *key,
                                    const gchar *value);
gboolean bubble_settings_config_unset(BubbleSettings *s, const gchar *key);
gboolean bubble_settings_apply(BubbleSettings *s);

GtkWidget *bubble_settings_page(const gchar *title, const gchar *subtitle);
GtkWidget *bubble_settings_card(const gchar *title);
GtkWidget *bubble_settings_grid(void);
void bubble_settings_add_row(GtkGrid *grid, gint row, const gchar *label,
                             GtkWidget *widget);
GtkWidget *bubble_settings_add_switch(GtkGrid *grid, gint row, const gchar *label,
                                      gboolean active);
GtkWidget *bubble_settings_add_spin(GtkGrid *grid, gint row, const gchar *label,
                                    gdouble min, gdouble max, gdouble step,
                                    gdouble value);
GtkWidget *bubble_settings_add_combo(GtkGrid *grid, gint row, const gchar *label,
                                     const gchar *current, gchar **choices);
GtkWidget *bubble_settings_add_entry(GtkGrid *grid, gint row, const gchar *label,
                                     const gchar *value);
void bubble_settings_add_apply(GtkWidget *page, GCallback cb, gpointer data);
gchar *bubble_settings_combo_text(GtkWidget *combo);

GtkWidget *bubble_settings_appearance_page(BubbleSettings *s);
GtkWidget *bubble_settings_wallpaper_page(BubbleSettings *s);
GtkWidget *bubble_settings_bar_page(BubbleSettings *s);
GtkWidget *bubble_settings_session_page(BubbleSettings *s);
GtkWidget *bubble_settings_users_page(BubbleSettings *s);
GtkWidget *bubble_settings_datetime_page(BubbleSettings *s);
GtkWidget *bubble_settings_system_page(BubbleSettings *s);
GtkWidget *bubble_settings_about_page(BubbleSettings *s);
