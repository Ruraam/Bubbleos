#define _GNU_SOURCE

#include "settings.h"

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define BUBBLE_SETTINGS_APPLICATION_ID "org.bubbleos.Settings"

static gboolean load_config(BubbleSettings *s);
static void sidebar_row_selected(GtkListBox *box, GtkListBoxRow *row,
                                 gpointer data);
static void search_changed(GtkSearchEntry *entry, gpointer data);

BubbleSettings *bubble_settings_new(GtkApplication *app)
{
    BubbleSettings *s = g_new0(BubbleSettings, 1);
    s->app = app;
    s->config = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_free);
    s->users = g_ptr_array_new_with_free_func(NULL);
    load_config(s);
    return s;
}

static gboolean write_input(gint fd, const gchar *input)
{
    size_t length;
    size_t written = 0;

    if (input == NULL) {
        return TRUE;
    }
    length = strlen(input);
    while (written < length) {
        ssize_t got = write(fd, input + written, length - written);
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            return FALSE;
        }
        written += (size_t)got;
    }
    return TRUE;
}

gboolean bubble_settings_run(BubbleSettings *s, gchar **argv, const gchar *input,
                             gchar **out, gchar **err)
{
    GError *error = NULL;
    GPid pid = 0;
    gint child_stdin = -1;
    gint child_stdout = -1;
    gint child_stderr = -1;
    gint status = 0;
    GString *stdout_buf = g_string_new(NULL);
    GString *stderr_buf = g_string_new(NULL);
    struct pollfd fds[2];
    gboolean input_ok = TRUE;
    gboolean spawned;

    (void)s;

    spawned = g_spawn_async_with_pipes(
        NULL, argv, NULL,
        G_SPAWN_SEARCH_PATH | G_SPAWN_DO_NOT_REAP_CHILD, NULL, NULL, &pid,
        &child_stdin, &child_stdout, &child_stderr, &error);
    if (!spawned) {
        if (err != NULL) {
            *err = g_strdup(error != NULL ? error->message : "spawn failed");
        }
        g_clear_error(&error);
        g_string_free(stdout_buf, TRUE);
        g_string_free(stderr_buf, TRUE);
        if (out != NULL) {
            *out = g_strdup("");
        }
        return FALSE;
    }

    input_ok = write_input(child_stdin, input);
    close(child_stdin);

    fds[0].fd = child_stdout;
    fds[0].events = POLLIN;
    fds[1].fd = child_stderr;
    fds[1].events = POLLIN;

    while (fds[0].fd >= 0 || fds[1].fd >= 0) {
        int ready = poll(fds, 2, -1);

        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        for (guint i = 0; i < 2; i++) {
            gchar buffer[4096];
            ssize_t got;

            if (fds[i].fd < 0) {
                continue;
            }
            if (fds[i].revents & (POLLERR | POLLNVAL)) {
                close(fds[i].fd);
                fds[i].fd = -1;
                continue;
            }
            if ((fds[i].revents & (POLLIN | POLLHUP)) == 0) {
                continue;
            }
            got = read(fds[i].fd, buffer, sizeof(buffer));
            if (got > 0) {
                g_string_append_len(i == 0 ? stdout_buf : stderr_buf, buffer,
                                    got);
            } else if (got == 0 || (got < 0 && errno != EINTR)) {
                close(fds[i].fd);
                fds[i].fd = -1;
            }
        }
    }
    if (fds[0].fd >= 0) {
        close(fds[0].fd);
    }
    if (fds[1].fd >= 0) {
        close(fds[1].fd);
    }

    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            break;
        }
    }
    g_spawn_close_pid(pid);

    if (out != NULL) {
        *out = g_string_free(stdout_buf, FALSE);
    } else {
        g_string_free(stdout_buf, TRUE);
    }
    if (err != NULL) {
        *err = g_string_free(stderr_buf, FALSE);
    } else {
        g_string_free(stderr_buf, TRUE);
    }

    if (!input_ok) {
        return FALSE;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void show_dialog(BubbleSettings *s, GtkMessageType type,
                        const gchar *primary, const gchar *detail)
{
    if (s->window == NULL || !gtk_widget_get_visible(s->window)) {
        fprintf(stderr, "bubble-settings: %s%s%s\n", primary,
                detail != NULL && *detail != '\0' ? ": " : "",
                detail != NULL ? detail : "");
        return;
    }

    GtkWidget *dialog = gtk_message_dialog_new(
        GTK_WINDOW(s->window),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, type,
        GTK_BUTTONS_CLOSE, "%s", primary);
    if (detail != NULL && *detail != '\0') {
        gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog),
                                                 "%s", detail);
    }
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

void bubble_settings_error(BubbleSettings *s, const gchar *fmt, ...)
{
    va_list args;
    gchar *message;

    va_start(args, fmt);
    message = g_strdup_vprintf(fmt, args);
    va_end(args);

    show_dialog(s, GTK_MESSAGE_ERROR, "Opération impossible", message);
    g_free(message);
}

void bubble_settings_info(BubbleSettings *s, const gchar *fmt, ...)
{
    va_list args;
    gchar *message;

    va_start(args, fmt);
    message = g_strdup_vprintf(fmt, args);
    va_end(args);

    show_dialog(s, GTK_MESSAGE_INFO, "bubbleOS", message);
    g_free(message);
}

static gboolean clear_status(gpointer data)
{
    BubbleSettings *s = data;
    if (s->status != NULL) {
        gtk_label_set_text(GTK_LABEL(s->status), "");
    }
    s->status_timeout = 0;
    return G_SOURCE_REMOVE;
}

void bubble_settings_status(BubbleSettings *s, const gchar *text)
{
    if (s->status == NULL) {
        return;
    }
    if (s->status_timeout != 0) {
        g_source_remove(s->status_timeout);
        s->status_timeout = 0;
    }
    gtk_label_set_text(GTK_LABEL(s->status), text);
    s->status_timeout = g_timeout_add(5000, clear_status, s);
}

static gboolean load_config(BubbleSettings *s)
{
    gchar *out = NULL;
    gchar *err = NULL;
    gchar *argv[] = {"bubble-desktop", "config", "show", NULL};

    if (!bubble_settings_run(s, argv, NULL, &out, &err)) {
        fprintf(stderr, "bubble-settings: cannot read desktop configuration: %s\n",
                err != NULL ? err : "unknown error");
        g_free(out);
        g_free(err);
        return FALSE;
    }

    gchar **lines = g_strsplit(out, "\n", -1);
    for (guint i = 0; lines[i] != NULL; i++) {
        gchar *line = lines[i];
        gchar *sep;

        if (*line == '\0') {
            continue;
        }
        sep = line;
        while (*sep != '\0' && *sep != ' ' && *sep != '\t') {
            sep++;
        }
        if (*sep == '\0') {
            continue;
        }
        *sep++ = '\0';
        while (*sep == ' ' || *sep == '\t') {
            sep++;
        }
        g_hash_table_replace(s->config, g_strdup(line), g_strdup(sep));
    }
    g_strfreev(lines);
    g_free(out);
    g_free(err);
    return TRUE;
}

const gchar *bubble_settings_config(BubbleSettings *s, const gchar *key)
{
    const gchar *value;

    if (s->config == NULL) {
        return "";
    }
    value = g_hash_table_lookup(s->config, key);
    return value != NULL ? value : "";
}

gboolean bubble_settings_config_set(BubbleSettings *s, const gchar *key,
                                    const gchar *value)
{
    gchar *out = NULL;
    gchar *err = NULL;
    gchar *argv[] = {"bubble-desktop", "config", "set", (gchar *)key,
                     (gchar *)value, NULL};

    if (!bubble_settings_run(s, argv, NULL, &out, &err)) {
        bubble_settings_error(s, "Impossible d’enregistrer %s.\n%s", key,
                              err != NULL ? err : "");
        g_free(out);
        g_free(err);
        return FALSE;
    }
    g_hash_table_replace(s->config, g_strdup(key), g_strdup(value));
    g_free(out);
    g_free(err);
    return TRUE;
}

gboolean bubble_settings_config_unset(BubbleSettings *s, const gchar *key)
{
    gchar *out = NULL;
    gchar *err = NULL;
    gchar *argv[] = {"bubble-desktop", "config", "unset", (gchar *)key, NULL};

    if (!bubble_settings_run(s, argv, NULL, &out, &err)) {
        bubble_settings_error(s, "Impossible de réinitialiser %s.\n%s", key,
                              err != NULL ? err : "");
        g_free(out);
        g_free(err);
        return FALSE;
    }
    g_hash_table_remove(s->config, key);
    g_free(out);
    g_free(err);
    return TRUE;
}

gboolean bubble_settings_apply(BubbleSettings *s)
{
    gchar *out = NULL;
    gchar *err = NULL;
    gchar *argv[] = {"bubble-desktop", "apply", NULL};
    gboolean ok = bubble_settings_run(s, argv, NULL, &out, &err);

    if (!ok) {
        bubble_settings_error(s, "Impossible d’appliquer les réglages.\n%s",
                              err != NULL ? err : "");
    }
    g_free(out);
    g_free(err);
    return ok;
}

static void load_css(void)
{
    GtkCssProvider *provider = gtk_css_provider_new();
    GError *error = NULL;
    gchar *path = g_strdup(BUBBLE_SETTINGS_CSS);

    if (!g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
        g_free(path);
        path = g_strdup("bubble-settings.css");
    }

    if (!gtk_css_provider_load_from_path(provider, path, &error)) {
        fprintf(stderr, "bubble-settings: cannot load %s: %s\n", path,
                error != NULL ? error->message : "unknown error");
        g_clear_error(&error);
    } else {
        gtk_style_context_add_provider_for_screen(
            gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider),
            GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
    g_object_unref(provider);
    g_free(path);
}

static GtkWidget *make_sidebar_row(const gchar *page, const gchar *icon,
                                   const gchar *label)
{
    GtkWidget *row = gtk_list_box_row_new();
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    GtkWidget *image = gtk_image_new_from_icon_name(icon, GTK_ICON_SIZE_MENU);
    GtkWidget *text = gtk_label_new(label);

    g_object_set_data_full(G_OBJECT(row), "page-id", g_strdup(page), g_free);
    g_object_set_data_full(G_OBJECT(row), "page-label", g_strdup(label), g_free);

    gtk_widget_set_margin_start(box, 4);
    gtk_widget_set_margin_end(box, 4);
    gtk_widget_set_margin_top(box, 2);
    gtk_widget_set_margin_bottom(box, 2);
    gtk_widget_set_halign(text, GTK_ALIGN_START);
    gtk_widget_set_hexpand(text, TRUE);

    gtk_box_pack_start(GTK_BOX(box), image, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), text, TRUE, TRUE, 0);
    gtk_container_add(GTK_CONTAINER(row), box);
    return row;
}

static void sidebar_row_selected(GtkListBox *box, GtkListBoxRow *row,
                                 gpointer data)
{
    BubbleSettings *s = data;
    const gchar *page;

    (void)box;

    if (row == NULL) {
        return;
    }
    page = g_object_get_data(G_OBJECT(row), "page-id");
    if (page != NULL) {
        gtk_stack_set_visible_child_name(GTK_STACK(s->stack), page);
    }
}

static void search_changed(GtkSearchEntry *entry, gpointer data)
{
    BubbleSettings *s = data;
    const gchar *needle = gtk_entry_get_text(GTK_ENTRY(entry));
    GList *rows = gtk_container_get_children(GTK_CONTAINER(s->sidebar));
    GtkListBoxRow *first_visible = NULL;
    GtkListBoxRow *selected = gtk_list_box_get_selected_row(GTK_LIST_BOX(s->sidebar));
    gchar *needle_folded = needle != NULL && *needle != '\0'
                               ? g_utf8_strdown(needle, -1)
                               : NULL;

    for (GList *item = rows; item != NULL; item = item->next) {
        GtkListBoxRow *row = GTK_LIST_BOX_ROW(item->data);
        const gchar *label = g_object_get_data(G_OBJECT(row), "page-label");
        gboolean visible = TRUE;

        if (needle_folded != NULL && label != NULL) {
            gchar *label_folded = g_utf8_strdown(label, -1);
            visible = g_strstr_len(label_folded, -1, needle_folded) != NULL;
            g_free(label_folded);
        }
        gtk_widget_set_visible(GTK_WIDGET(row), visible);
        if (visible && first_visible == NULL) {
            first_visible = row;
        }
    }
    g_list_free(rows);
    g_free(needle_folded);

    if (selected != NULL && !gtk_widget_get_visible(GTK_WIDGET(selected)) &&
        first_visible != NULL) {
        gtk_list_box_select_row(GTK_LIST_BOX(s->sidebar), first_visible);
    }
}

void bubble_settings_select_page(BubbleSettings *s, const gchar *page)
{
    GList *rows;

    if (s->sidebar == NULL || page == NULL) {
        return;
    }
    rows = gtk_container_get_children(GTK_CONTAINER(s->sidebar));
    for (GList *item = rows; item != NULL; item = item->next) {
        GtkListBoxRow *row = GTK_LIST_BOX_ROW(item->data);
        const gchar *id = g_object_get_data(G_OBJECT(row), "page-id");
        if (g_strcmp0(id, page) == 0) {
            gtk_list_box_select_row(GTK_LIST_BOX(s->sidebar), row);
            break;
        }
    }
    g_list_free(rows);
}

void bubble_settings_build_window(BubbleSettings *s)
{
    GtkWidget *header;
    GtkWidget *title_box;
    GtkWidget *title;
    GtkWidget *subtitle;
    GtkWidget *main_box;
    GtkWidget *sidebar_box;
    GtkWidget *sidebar_scroll;
    GtkWidget *content_box;
    GtkWidget *content_scroll;

    load_css();

    s->window = gtk_application_window_new(s->app);
    gtk_window_set_title(GTK_WINDOW(s->window), "Paramètres bubbleOS");
    gtk_window_set_default_size(GTK_WINDOW(s->window), 1040, 740);
    gtk_window_set_icon_name(GTK_WINDOW(s->window), "bubbleos-settings");

    header = gtk_header_bar_new();
    gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header), TRUE);
    title_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    title = gtk_label_new("Paramètres bubbleOS");
    subtitle = gtk_label_new("Centre de contrôle du bureau");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_widget_set_halign(subtitle, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(title),
                                "window-title");
    gtk_style_context_add_class(gtk_widget_get_style_context(subtitle),
                                "window-subtitle");
    gtk_box_pack_start(GTK_BOX(title_box), title, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(title_box), subtitle, FALSE, FALSE, 0);
    gtk_header_bar_set_custom_title(GTK_HEADER_BAR(header), title_box);
    gtk_window_set_titlebar(GTK_WINDOW(s->window), header);

    main_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_container_add(GTK_CONTAINER(s->window), main_box);

    sidebar_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_style_context_add_class(gtk_widget_get_style_context(sidebar_box),
                                "sidebar");
    gtk_widget_set_size_request(sidebar_box, 260, -1);
    gtk_box_pack_start(GTK_BOX(main_box), sidebar_box, FALSE, FALSE, 0);

    s->search = gtk_search_entry_new();
    gtk_entry_set_placeholder_text(GTK_ENTRY(s->search),
                                   "Rechercher un réglage…");
    gtk_widget_set_margin_start(s->search, 12);
    gtk_widget_set_margin_end(s->search, 12);
    gtk_widget_set_margin_top(s->search, 12);
    gtk_widget_set_margin_bottom(s->search, 8);
    g_signal_connect(s->search, "changed", G_CALLBACK(search_changed), s);
    gtk_box_pack_start(GTK_BOX(sidebar_box), s->search, FALSE, FALSE, 0);

    s->sidebar = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(s->sidebar),
                                    GTK_SELECTION_SINGLE);
    gtk_style_context_add_class(gtk_widget_get_style_context(s->sidebar),
                                "sidebar-list");
    g_signal_connect(s->sidebar, "row-selected",
                     G_CALLBACK(sidebar_row_selected), s);

    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("appearance", "preferences-desktop-theme",
                                         "Apparence"), -1);
    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("wallpaper", "preferences-desktop-wallpaper",
                                         "Fond d’écran"), -1);
    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("bar", "preferences-system",
                                         "Barre & notifications"), -1);
    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("session", "preferences-desktop-screensaver",
                                         "Session"), -1);
    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("users", "system-users", "Utilisateurs"), -1);
    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("datetime", "preferences-system-time",
                                         "Date & heure"), -1);
    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("system", "applications-system",
                                         "Système"), -1);
    gtk_list_box_insert(GTK_LIST_BOX(s->sidebar),
                        make_sidebar_row("about", "help-about", "À propos"), -1);

    sidebar_scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(sidebar_scroll),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_container_add(GTK_CONTAINER(sidebar_scroll), s->sidebar);
    gtk_box_pack_start(GTK_BOX(sidebar_box), sidebar_scroll, TRUE, TRUE, 0);

    content_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_hexpand(content_box, TRUE);
    gtk_box_pack_start(GTK_BOX(main_box), content_box, TRUE, TRUE, 0);

    s->stack = gtk_stack_new();
    gtk_stack_set_transition_type(GTK_STACK(s->stack),
                                  GTK_STACK_TRANSITION_TYPE_SLIDE_LEFT_RIGHT);
    gtk_stack_set_transition_duration(GTK_STACK(s->stack), 180);
    gtk_widget_set_hexpand(s->stack, TRUE);
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_appearance_page(s), "appearance");
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_wallpaper_page(s), "wallpaper");
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_bar_page(s), "bar");
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_session_page(s), "session");
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_users_page(s), "users");
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_datetime_page(s), "datetime");
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_system_page(s), "system");
    gtk_stack_add_named(GTK_STACK(s->stack),
                        bubble_settings_about_page(s), "about");

    content_scroll = gtk_scrolled_window_new(NULL, NULL);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(content_scroll),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_hexpand(content_scroll, TRUE);
    gtk_widget_set_vexpand(content_scroll, TRUE);
    gtk_container_add(GTK_CONTAINER(content_scroll), s->stack);
    gtk_box_pack_start(GTK_BOX(content_box), content_scroll, TRUE, TRUE, 0);

    s->status = gtk_label_new("");
    gtk_widget_set_halign(s->status, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(s->status),
                                "status");
    gtk_box_pack_start(GTK_BOX(content_box), s->status, FALSE, FALSE, 0);

    gtk_list_box_select_row(GTK_LIST_BOX(s->sidebar),
                            GTK_LIST_BOX_ROW(gtk_list_box_get_row_at_index(
                                GTK_LIST_BOX(s->sidebar), 0)));
}

static gboolean smoke_quit(gpointer data)
{
    g_application_quit(G_APPLICATION(data));
    return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *app, gpointer data)
{
    BubbleSettings *s = data;

    if (s->window == NULL) {
        bubble_settings_build_window(s);
    }
    gtk_widget_show_all(s->window);
    gtk_window_present(GTK_WINDOW(s->window));
    if (s->initial_page != NULL && *s->initial_page != '\0') {
        bubble_settings_select_page(s, s->initial_page);
    }
    if (s->smoke_test) {
        g_timeout_add(1500, smoke_quit, app);
    }
}

static gboolean file_check(const gchar *path, const gchar *label)
{
    gboolean ok = g_file_test(path, G_FILE_TEST_IS_REGULAR);
    printf("[%s] %s: %s\n", ok ? "OK" : "FAIL", label, path);
    return ok;
}

static gboolean executable_check(const gchar *path, const gchar *label)
{
    gboolean ok = g_file_test(path, G_FILE_TEST_IS_EXECUTABLE);
    printf("[%s] %s: %s\n", ok ? "OK" : "FAIL", label, path);
    return ok;
}

static gboolean command_check(const gchar *name, gboolean required)
{
    gchar *path = g_find_program_in_path(name);
    gboolean ok = path != NULL;

    /* Administrative commands live in sbin directories that are not part of
     * the default unprivileged PATH. */
    if (!ok) {
        const gchar *dirs[] = {"/usr/sbin", "/sbin", "/usr/local/sbin", NULL};
        for (guint i = 0; dirs[i] != NULL && !ok; i++) {
            gchar *candidate = g_build_filename(dirs[i], name, NULL);
            ok = g_file_test(candidate, G_FILE_TEST_IS_EXECUTABLE);
            g_free(candidate);
        }
    }
    printf("[%s] command: %s%s\n", ok ? "OK" : (required ? "FAIL" : "WARN"),
           name, ok ? "" : " (missing)");
    g_free(path);
    return ok || !required;
}

static gboolean policy_check(const gchar *path)
{
    gchar *contents = NULL;
    gboolean ok = FALSE;

    if (g_file_get_contents(path, &contents, NULL, NULL)) {
        ok = strstr(contents, "org.bubbleos.settings.users") != NULL &&
             strstr(contents, BUBBLE_SETTINGS_HELPER) != NULL;
    }
    printf("[%s] polkit action: %s\n", ok ? "OK" : "FAIL", path);
    g_free(contents);
    return ok;
}

static int doctor(void)
{
    gboolean ok = TRUE;

    printf("bubble-settings %s doctor\n\n", BUBBLE_SETTINGS_VERSION);
    ok &= file_check(BUBBLE_SETTINGS_CSS, "stylesheet");
    ok &= executable_check(BUBBLE_SETTINGS_HELPER, "privileged helper");
    ok &= policy_check("/usr/share/polkit-1/actions/org.bubbleos.settings.policy");
    ok &= file_check("/usr/share/applications/bubble-settings.desktop",
                     "desktop entry");
    ok &= file_check("/usr/share/icons/hicolor/scalable/apps/bubbleos-settings.svg",
                     "application icon");

    printf("\nCommands\n");
    ok &= command_check("bubble-desktop", TRUE);
    ok &= command_check("pkexec", TRUE);
    ok &= command_check("useradd", TRUE);
    ok &= command_check("usermod", TRUE);
    ok &= command_check("userdel", TRUE);
    ok &= command_check("chpasswd", TRUE);
    ok &= command_check("lxpolkit", TRUE);
    ok &= command_check("nm-connection-editor", FALSE);
    ok &= command_check("pavucontrol", FALSE);
    ok &= command_check("wcm", FALSE);
    ok &= command_check("bluetoothctl", FALSE);
    ok &= command_check("foot", FALSE);
    ok &= command_check("wlr-randr", FALSE);
    ok &= command_check("timedatectl", FALSE);
    ok &= command_check("localectl", FALSE);

    printf("\n%s\n", ok ? "doctor: all checks passed" : "doctor: failures found");
    return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}

static void usage(const char *program)
{
    printf("Usage: %s [options]\n\n", program);
    printf("Options:\n");
    printf("  --page <id>    Open a page (appearance, wallpaper, bar, session,\n");
    printf("                 users, datetime, system, about)\n");
    printf("  --smoke-test   Open the window, then exit after 1.5 seconds\n");
    printf("  --doctor       Check the installation without opening a window\n");
    printf("  --version      Print the version\n");
    printf("  --help         Show this help\n");
}

int main(int argc, char **argv)
{
    GtkApplication *app;
    BubbleSettings *s;
    const gchar *page = NULL;
    gboolean smoke_test = FALSE;
    int status;

    /* A helper may exit before reading its password (invalid input, polkit
     * refusal); writing to the closed pipe must not terminate the UI. */
    signal(SIGPIPE, SIG_IGN);

    for (int i = 1; i < argc; i++) {
        if (g_strcmp0(argv[i], "--version") == 0) {
            printf("bubble-settings %s\n", BUBBLE_SETTINGS_VERSION);
            return EXIT_SUCCESS;
        }
        if (g_strcmp0(argv[i], "--doctor") == 0 ||
            g_strcmp0(argv[i], "--check") == 0) {
            return doctor();
        }
        if (g_strcmp0(argv[i], "--help") == 0 ||
            g_strcmp0(argv[i], "-h") == 0) {
            usage(argv[0]);
            return EXIT_SUCCESS;
        }
        if (g_strcmp0(argv[i], "--page") == 0 && i + 1 < argc) {
            page = argv[++i];
            continue;
        }
        if (g_strcmp0(argv[i], "--smoke-test") == 0) {
            smoke_test = TRUE;
            continue;
        }
        fprintf(stderr, "bubble-settings: unknown option: %s\n", argv[i]);
        usage(argv[0]);
        return EXIT_FAILURE;
    }

    app = gtk_application_new(BUBBLE_SETTINGS_APPLICATION_ID,
                              G_APPLICATION_DEFAULT_FLAGS);
    s = bubble_settings_new(app);
    s->initial_page = g_strdup(page);
    s->smoke_test = smoke_test;
    g_signal_connect(app, "activate", G_CALLBACK(activate), s);
    {
        /* Custom options are handled above; GTK must not parse them. */
        gchar *app_argv[] = {argv[0], NULL};
        status = g_application_run(G_APPLICATION(app), 1, app_argv);
    }
    g_object_unref(app);
    return status;
}
