#define _GNU_SOURCE

#include "settings.h"

#include <grp.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void user_free(gpointer data)
{
    BubbleUser *user = data;

    if (user == NULL) {
        return;
    }
    g_free(user->name);
    g_free(user->gecos);
    g_free(user->home);
    g_free(user->shell);
    g_free(user);
}

static gboolean user_is_human(const struct passwd *pw)
{
    const gchar *shell;

    if (pw == NULL || pw->pw_uid < 1000 || pw->pw_uid >= 60000) {
        return FALSE;
    }
    if (g_strcmp0(pw->pw_name, "nobody") == 0) {
        return FALSE;
    }
    shell = pw->pw_shell;
    if (shell == NULL || *shell == '\0') {
        return FALSE;
    }
    if (g_str_has_suffix(shell, "nologin") || g_str_has_suffix(shell, "/false")) {
        return FALSE;
    }
    return TRUE;
}

static gboolean user_is_admin(const gchar *name)
{
    struct group *group = getgrnam("sudo");

    if (group == NULL) {
        return FALSE;
    }
    for (gchar **member = group->gr_mem; member != NULL && *member != NULL;
         member++) {
        if (g_strcmp0(*member, name) == 0) {
            return TRUE;
        }
    }
    struct passwd *pw = getpwnam(name);
    return pw != NULL && pw->pw_gid == group->gr_gid;
}

static gint compare_users(gconstpointer a, gconstpointer b)
{
    const BubbleUser *left = *(const BubbleUser *const *)a;
    const BubbleUser *right = *(const BubbleUser *const *)b;

    if (left->uid < right->uid) {
        return -1;
    }
    if (left->uid > right->uid) {
        return 1;
    }
    return g_strcmp0(left->name, right->name);
}

static void update_users_buttons(BubbleSettings *s)
{
    GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(s->users_list));
    BubbleUser *user = row != NULL ? g_object_get_data(G_OBJECT(row), "user") : NULL;
    gboolean self = user != NULL && user->uid == getuid();

    gtk_widget_set_sensitive(s->users_password, user != NULL);
    gtk_widget_set_sensitive(s->users_delete, user != NULL && !self);
    if (user == NULL) {
        gtk_label_set_text(GTK_LABEL(s->users_info),
                           "Sélectionnez un compte pour le modifier.");
    } else if (self) {
        gtk_label_set_text(GTK_LABEL(s->users_info),
                           "C’est votre compte : la suppression est désactivée.");
    } else if (user->admin) {
        gtk_label_set_text(GTK_LABEL(s->users_info),
                           "Ce compte est administrateur (groupe sudo).");
    } else {
        gtk_label_set_text(GTK_LABEL(s->users_info),
                           "Compte standard sans privilèges sudo.");
    }
}

static void users_selection_changed(GtkListBox *box, GtkListBoxRow *row,
                                    gpointer data)
{
    (void)box;
    (void)row;
    update_users_buttons(data);
}

static void users_refresh(BubbleSettings *s)
{
    GList *children;
    struct passwd *pw;

    children = gtk_container_get_children(GTK_CONTAINER(s->users_list));
    for (GList *item = children; item != NULL; item = item->next) {
        gtk_widget_destroy(GTK_WIDGET(item->data));
    }
    g_list_free(children);
    g_ptr_array_set_size(s->users, 0);

    setpwent();
    while ((pw = getpwent()) != NULL) {
        BubbleUser *user;

        if (!user_is_human(pw)) {
            continue;
        }
        user = g_new0(BubbleUser, 1);
        user->name = g_strdup(pw->pw_name);
        user->gecos = g_strdup(pw->pw_gecos != NULL && *pw->pw_gecos != '\0'
                                   ? pw->pw_gecos
                                   : pw->pw_name);
        user->uid = pw->pw_uid;
        user->gid = pw->pw_gid;
        user->home = g_strdup(pw->pw_dir);
        user->shell = g_strdup(pw->pw_shell);
        user->admin = user_is_admin(pw->pw_name);
        g_ptr_array_add(s->users, user);
    }
    endpwent();
    g_ptr_array_sort(s->users, compare_users);

    gboolean selected = FALSE;
    for (guint i = 0; i < s->users->len; i++) {
        BubbleUser *user = g_ptr_array_index(s->users, i);
        GtkWidget *row = gtk_list_box_row_new();
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
        GtkWidget *avatar = gtk_image_new_from_icon_name(
            "avatar-default-symbolic", GTK_ICON_SIZE_DND);
        GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        GtkWidget *name = gtk_label_new(user->gecos);
        gchar *detail_text = g_strdup_printf("%s · UID %u", user->name,
                                             (unsigned)user->uid);
        GtkWidget *detail = gtk_label_new(detail_text);
        GtkWidget *badges = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);

        gtk_widget_set_halign(name, GTK_ALIGN_START);
        gtk_widget_set_halign(detail, GTK_ALIGN_START);
        gtk_style_context_add_class(gtk_widget_get_style_context(name),
                                    "user-name");
        gtk_style_context_add_class(gtk_widget_get_style_context(detail),
                                    "user-detail");
        gtk_style_context_add_class(gtk_widget_get_style_context(avatar),
                                    "user-avatar");
        if (user->admin) {
            GtkWidget *badge = gtk_label_new("administrateur");
            gtk_style_context_add_class(gtk_widget_get_style_context(badge),
                                        "admin-badge");
            gtk_box_pack_start(GTK_BOX(badges), badge, FALSE, FALSE, 0);
        }
        if (user->uid == getuid()) {
            GtkWidget *badge = gtk_label_new("vous");
            gtk_style_context_add_class(gtk_widget_get_style_context(badge),
                                        "self-badge");
            gtk_box_pack_start(GTK_BOX(badges), badge, FALSE, FALSE, 0);
        }
        gtk_box_pack_start(GTK_BOX(text), name, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(text), detail, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(box), avatar, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(box), text, TRUE, TRUE, 0);
        gtk_box_pack_end(GTK_BOX(box), badges, FALSE, FALSE, 0);
        gtk_container_add(GTK_CONTAINER(row), box);
        g_object_set_data(G_OBJECT(row), "user", user);
        gtk_list_box_insert(GTK_LIST_BOX(s->users_list), row, -1);
        gtk_widget_show_all(row);
        g_free(detail_text);

        if (!selected) {
            gtk_list_box_select_row(GTK_LIST_BOX(s->users_list),
                                    GTK_LIST_BOX_ROW(row));
            selected = TRUE;
        }
    }
    update_users_buttons(s);
}

static gboolean run_helper(BubbleSettings *s, gchar **args, const gchar *input,
                           gchar **err)
{
    gsize count = g_strv_length(args);
    gchar **argv = g_new0(gchar *, count + 3);
    gboolean ok;

    argv[0] = "pkexec";
    argv[1] = BUBBLE_SETTINGS_HELPER;
    for (gsize i = 0; i < count; i++) {
        argv[i + 2] = args[i];
    }
    ok = bubble_settings_run(s, argv, input, NULL, err);
    g_free(argv);
    return ok;
}

static void users_refresh_clicked(GtkButton *button, gpointer data)
{
    (void)button;
    users_refresh(data);
}

static void users_add_clicked(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    GtkWidget *dialog = gtk_dialog_new_with_buttons(
        "Ajouter un utilisateur", GTK_WINDOW(s->window),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, "Annuler",
        GTK_RESPONSE_CANCEL, "Créer", GTK_RESPONSE_ACCEPT, NULL);
    GtkWidget *content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    GtkWidget *grid = gtk_grid_new();
    GtkWidget *username = gtk_entry_new();
    GtkWidget *fullname = gtk_entry_new();
    GtkWidget *password = gtk_entry_new();
    GtkWidget *confirm = gtk_entry_new();
    GtkWidget *admin = gtk_check_button_new_with_label(
        "Administrateur (groupe sudo)");
    GtkWidget *home = gtk_check_button_new_with_label(
        "Créer le dossier personnel");

    (void)button;

    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 16);
    gtk_widget_set_margin_start(grid, 18);
    gtk_widget_set_margin_end(grid, 18);
    gtk_widget_set_margin_top(grid, 12);
    gtk_widget_set_margin_bottom(grid, 12);

    gtk_entry_set_placeholder_text(GTK_ENTRY(username), "ex. alice");
    gtk_entry_set_placeholder_text(GTK_ENTRY(fullname), "Nom complet (optionnel)");
    gtk_entry_set_visibility(GTK_ENTRY(password), FALSE);
    gtk_entry_set_visibility(GTK_ENTRY(confirm), FALSE);
    gtk_entry_set_input_purpose(GTK_ENTRY(password), GTK_INPUT_PURPOSE_PASSWORD);
    gtk_entry_set_input_purpose(GTK_ENTRY(confirm), GTK_INPUT_PURPOSE_PASSWORD);
    gtk_entry_set_activates_default(GTK_ENTRY(username), TRUE);
    gtk_entry_set_activates_default(GTK_ENTRY(fullname), TRUE);
    gtk_entry_set_activates_default(GTK_ENTRY(password), TRUE);
    gtk_entry_set_activates_default(GTK_ENTRY(confirm), TRUE);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(home), TRUE);
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);

    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Identifiant"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), username, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Nom complet"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), fullname, 1, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Mot de passe"), 0, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), password, 1, 2, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Confirmation"), 0, 3, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), confirm, 1, 3, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), admin, 1, 4, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), home, 1, 5, 1, 1);
    gtk_container_add(GTK_CONTAINER(content), grid);
    gtk_widget_show_all(dialog);

    while (TRUE) {
        gint response = gtk_dialog_run(GTK_DIALOG(dialog));
        const gchar *user = gtk_entry_get_text(GTK_ENTRY(username));
        const gchar *name = gtk_entry_get_text(GTK_ENTRY(fullname));
        const gchar *pass = gtk_entry_get_text(GTK_ENTRY(password));
        const gchar *again = gtk_entry_get_text(GTK_ENTRY(confirm));
        gchar *args[6];
        gchar *err = NULL;

        if (response != GTK_RESPONSE_ACCEPT) {
            break;
        }
        if (!g_regex_match_simple("^[a-z_][a-z0-9_-]{0,31}$", user, 0, 0)) {
            bubble_settings_error(
                s, "Identifiant invalide. Utilisez des minuscules, chiffres, "
                   "tirets ou underscores, en commençant par une lettre.");
            continue;
        }
        if (strlen(pass) < 8) {
            bubble_settings_error(s, "Le mot de passe doit contenir au moins 8 caractères.");
            continue;
        }
        if (g_strcmp0(pass, again) != 0) {
            bubble_settings_error(s, "Les deux mots de passe ne correspondent pas.");
            continue;
        }
        args[0] = "add";
        args[1] = (gchar *)user;
        args[2] = (gchar *)name;
        args[3] = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(admin)) ? "1" : "0";
        args[4] = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(home)) ? "1" : "0";
        args[5] = NULL;
        if (!run_helper(s, args, pass, &err)) {
            bubble_settings_error(s, "Impossible de créer l’utilisateur.\n%s",
                                  err != NULL ? err : "");
            g_free(err);
            continue;
        }
        gtk_entry_set_text(GTK_ENTRY(password), "");
        gtk_entry_set_text(GTK_ENTRY(confirm), "");
        bubble_settings_status(s, "Utilisateur créé.");
        users_refresh(s);
        break;
    }
    gtk_widget_destroy(dialog);
}

static BubbleUser *selected_user(BubbleSettings *s)
{
    GtkListBoxRow *row = gtk_list_box_get_selected_row(GTK_LIST_BOX(s->users_list));
    return row != NULL ? g_object_get_data(G_OBJECT(row), "user") : NULL;
}

static void users_password_clicked(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    BubbleUser *user = selected_user(s);
    GtkWidget *dialog;
    GtkWidget *content;
    GtkWidget *grid;
    GtkWidget *password;
    GtkWidget *confirm;
    GtkWidget *force;
    gchar *title;

    (void)button;

    if (user == NULL) {
        return;
    }
    title = g_strdup_printf("Mot de passe de %s", user->name);
    dialog = gtk_dialog_new_with_buttons(
        title, GTK_WINDOW(s->window),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, "Annuler",
        GTK_RESPONSE_CANCEL, "Enregistrer", GTK_RESPONSE_ACCEPT, NULL);
    content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    grid = gtk_grid_new();
    password = gtk_entry_new();
    confirm = gtk_entry_new();
    force = gtk_check_button_new_with_label(
        "Demander le changement à la prochaine connexion");

    gtk_grid_set_row_spacing(GTK_GRID(grid), 10);
    gtk_grid_set_column_spacing(GTK_GRID(grid), 16);
    gtk_widget_set_margin_start(grid, 18);
    gtk_widget_set_margin_end(grid, 18);
    gtk_widget_set_margin_top(grid, 12);
    gtk_widget_set_margin_bottom(grid, 12);
    gtk_entry_set_visibility(GTK_ENTRY(password), FALSE);
    gtk_entry_set_visibility(GTK_ENTRY(confirm), FALSE);
    gtk_entry_set_input_purpose(GTK_ENTRY(password), GTK_INPUT_PURPOSE_PASSWORD);
    gtk_entry_set_input_purpose(GTK_ENTRY(confirm), GTK_INPUT_PURPOSE_PASSWORD);
    gtk_entry_set_activates_default(GTK_ENTRY(password), TRUE);
    gtk_entry_set_activates_default(GTK_ENTRY(confirm), TRUE);
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);

    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Nouveau mot de passe"), 0, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), password, 1, 0, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), gtk_label_new("Confirmation"), 0, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), confirm, 1, 1, 1, 1);
    gtk_grid_attach(GTK_GRID(grid), force, 1, 2, 1, 1);
    gtk_container_add(GTK_CONTAINER(content), grid);
    gtk_widget_show_all(dialog);

    while (TRUE) {
        gint response = gtk_dialog_run(GTK_DIALOG(dialog));
        const gchar *pass = gtk_entry_get_text(GTK_ENTRY(password));
        const gchar *again = gtk_entry_get_text(GTK_ENTRY(confirm));
        gchar *args[4];
        gchar *err = NULL;

        if (response != GTK_RESPONSE_ACCEPT) {
            break;
        }
        if (strlen(pass) < 8) {
            bubble_settings_error(s, "Le mot de passe doit contenir au moins 8 caractères.");
            continue;
        }
        if (g_strcmp0(pass, again) != 0) {
            bubble_settings_error(s, "Les deux mots de passe ne correspondent pas.");
            continue;
        }
        args[0] = "passwd";
        args[1] = user->name;
        args[2] = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(force)) ? "1" : "0";
        args[3] = NULL;
        if (!run_helper(s, args, pass, &err)) {
            bubble_settings_error(s, "Impossible de changer le mot de passe.\n%s",
                                  err != NULL ? err : "");
            g_free(err);
            continue;
        }
        gtk_entry_set_text(GTK_ENTRY(password), "");
        gtk_entry_set_text(GTK_ENTRY(confirm), "");
        bubble_settings_status(s, "Mot de passe mis à jour.");
        break;
    }
    gtk_widget_destroy(dialog);
    g_free(title);
}

static void users_delete_clicked(GtkButton *button, gpointer data)
{
    BubbleSettings *s = data;
    BubbleUser *user = selected_user(s);
    GtkWidget *dialog;
    GtkWidget *content;
    GtkWidget *box;
    GtkWidget *label;
    GtkWidget *remove_home;
    gchar *title;
    gchar *message;

    (void)button;

    if (user == NULL) {
        return;
    }
    if (user->uid == getuid()) {
        bubble_settings_error(s, "Vous ne pouvez pas supprimer votre propre compte.");
        return;
    }
    title = g_strdup_printf("Supprimer %s", user->name);
    message = g_strdup_printf(
        "Le compte « %s » et son accès au système seront supprimés. "
        "Cette action est irréversible.", user->name);
    dialog = gtk_dialog_new_with_buttons(
        title, GTK_WINDOW(s->window),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT, "Annuler",
        GTK_RESPONSE_CANCEL, "Supprimer", GTK_RESPONSE_ACCEPT, NULL);
    content = gtk_dialog_get_content_area(GTK_DIALOG(dialog));
    box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    label = gtk_label_new(message);
    remove_home = gtk_check_button_new_with_label(
        "Supprimer aussi le dossier personnel et les fichiers");
    gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(label), 60);
    gtk_widget_set_halign(label, GTK_ALIGN_START);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(remove_home), TRUE);
    gtk_widget_set_margin_start(box, 18);
    gtk_widget_set_margin_end(box, 18);
    gtk_widget_set_margin_top(box, 12);
    gtk_widget_set_margin_bottom(box, 12);
    gtk_box_pack_start(GTK_BOX(box), label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(box), remove_home, FALSE, FALSE, 0);
    gtk_container_add(GTK_CONTAINER(content), box);
    gtk_widget_show_all(dialog);

    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        gchar *args[4];
        gchar *err = NULL;
        args[0] = "delete";
        args[1] = user->name;
        args[2] = gtk_toggle_button_get_active(GTK_TOGGLE_BUTTON(remove_home))
                      ? "1"
                      : "0";
        args[3] = NULL;
        if (!run_helper(s, args, NULL, &err)) {
            bubble_settings_error(s, "Impossible de supprimer l’utilisateur.\n%s",
                                  err != NULL ? err : "");
            g_free(err);
        } else {
            bubble_settings_status(s, "Utilisateur supprimé.");
            users_refresh(s);
        }
    }
    gtk_widget_destroy(dialog);
    g_free(title);
    g_free(message);
}

GtkWidget *bubble_settings_users_page(BubbleSettings *s)
{
    GtkWidget *page = bubble_settings_page(
        "Utilisateurs",
        "Ajouter, supprimer et sécuriser les comptes locaux de bubbleOS.");
    GtkWidget *card = bubble_settings_card("Comptes locaux");
    GtkWidget *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *add = gtk_button_new_with_label("Ajouter un utilisateur");
    GtkWidget *refresh = gtk_button_new_with_label("Actualiser");
    GtkWidget *list_scroll = gtk_scrolled_window_new(NULL, NULL);
    GtkWidget *actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);

    g_ptr_array_set_free_func(s->users, user_free);
    s->users_list = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(s->users_list),
                                    GTK_SELECTION_SINGLE);
    gtk_style_context_add_class(gtk_widget_get_style_context(s->users_list),
                                "users-list");
    g_signal_connect(s->users_list, "row-selected",
                     G_CALLBACK(users_selection_changed), s);
    gtk_widget_set_size_request(list_scroll, -1, 300);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(list_scroll),
                                   GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_container_add(GTK_CONTAINER(list_scroll), s->users_list);

    gtk_style_context_add_class(gtk_widget_get_style_context(add),
                                "suggested-action");
    g_signal_connect(add, "clicked", G_CALLBACK(users_add_clicked), s);
    g_signal_connect(refresh, "clicked", G_CALLBACK(users_refresh_clicked), s);
    gtk_box_pack_start(GTK_BOX(toolbar), add, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(toolbar), refresh, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(card), toolbar, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(card), list_scroll, TRUE, TRUE, 0);

    s->users_password = gtk_button_new_with_label("Changer le mot de passe");
    s->users_delete = gtk_button_new_with_label("Supprimer");
    gtk_style_context_add_class(gtk_widget_get_style_context(s->users_delete),
                                "destructive-action");
    g_signal_connect(s->users_password, "clicked",
                     G_CALLBACK(users_password_clicked), s);
    g_signal_connect(s->users_delete, "clicked",
                     G_CALLBACK(users_delete_clicked), s);
    gtk_box_pack_start(GTK_BOX(actions), s->users_password, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(actions), s->users_delete, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(card), actions, FALSE, FALSE, 0);

    s->users_info = gtk_label_new("Sélectionnez un compte pour le modifier.");
    gtk_widget_set_halign(s->users_info, GTK_ALIGN_START);
    gtk_label_set_line_wrap(GTK_LABEL(s->users_info), TRUE);
    gtk_style_context_add_class(gtk_widget_get_style_context(s->users_info),
                                "hint");
    gtk_box_pack_start(GTK_BOX(card), s->users_info, FALSE, FALSE, 0);

    gtk_box_pack_start(GTK_BOX(page), card, FALSE, FALSE, 0);
    GtkWidget *note = gtk_label_new(
        "Les opérations sur les comptes demandent l’authentification d’un "
        "administrateur via polkit. Le dernier administrateur ne peut pas être "
        "supprimé.");
    gtk_label_set_line_wrap(GTK_LABEL(note), TRUE);
    gtk_label_set_max_width_chars(GTK_LABEL(note), 80);
    gtk_widget_set_halign(note, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(note), "hint");
    gtk_box_pack_start(GTK_BOX(page), note, FALSE, FALSE, 0);

    users_refresh(s);
    return page;
}
