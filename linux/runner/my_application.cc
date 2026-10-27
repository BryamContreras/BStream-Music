#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* csv_channel;
  FlValue* csv_pending;
  gboolean csv_ready;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void csv_method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                               gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "start") == 0) {
    self->csv_ready = TRUE;
    fl_method_call_respond_success(call, self->csv_pending, nullptr);
    g_clear_pointer(&self->csv_pending, fl_value_unref);
    self->csv_pending = fl_value_new_list();
  } else if (g_strcmp0(method, "stop") == 0) {
    self->csv_ready = FALSE;
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else if (g_strcmp0(method, "release") == 0) {
    // Linux opens the original document and never removes it.
    fl_method_call_respond_success(call, nullptr, nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}

static void csv_accept_file(MyApplication* self, GFile* file) {
  g_autofree gchar* path = g_file_get_path(file);
  g_autofree gchar* name = g_file_get_basename(file);
  if (!path || !name) return;
  g_autofree gchar* lower = g_ascii_strdown(name, -1);
  if (!g_str_has_suffix(lower, ".csv")) return;
  g_autofree gchar* id = g_uuid_string_random();
  g_autofree gchar* source = g_file_get_uri(file);
  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "id", fl_value_new_string(id));
  fl_value_set_string_take(event, "path", fl_value_new_string(path));
  fl_value_set_string_take(event, "name", fl_value_new_string(name));
  fl_value_set_string_take(event, "source", fl_value_new_string(source));
  fl_value_set_string_take(event, "temporary", fl_value_new_bool(FALSE));
  if (!self->csv_ready || !self->csv_channel) {
    fl_value_append(self->csv_pending, event);
  } else {
    fl_method_channel_invoke_method(self->csv_channel, "open", event, nullptr,
                                    nullptr, nullptr);
  }
}

static gint csv_command_line_cb(GApplication* application,
                                GApplicationCommandLine* command_line,
                                gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_auto(GStrv) arguments =
      g_application_command_line_get_arguments(command_line, nullptr);
  const gchar* cwd = g_application_command_line_get_cwd(command_line);
  for (gchar** argument = arguments + 1; *argument; ++argument) {
    g_autoptr(GFile) file =
        g_file_new_for_commandline_arg_and_cwd(*argument, cwd);
    csv_accept_file(self, file);
  }
  return 0;
}

static void csv_open_cb(GApplication* application, GFile** files, gint count,
                        gchar* hint, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_application_activate(application);
  for (gint index = 0; index < count; ++index) csv_accept_file(self, files[index]);
}

static void window_method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                                  gpointer user_data) {
  GtkWidget* view = GTK_WIDGET(user_data);
  if (g_strcmp0(fl_method_call_get_name(call), "toggleFullScreen") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  GtkWindow* window = GTK_WINDOW(gtk_widget_get_toplevel(view));
  GdkWindow* native_window = gtk_widget_get_window(GTK_WIDGET(window));
  if (native_window == nullptr) {
    fl_method_call_respond_error(call, "window_unavailable",
                                 "The window has not been realized", nullptr,
                                 nullptr);
    return;
  }
  if (gdk_window_get_state(native_window) & GDK_WINDOW_STATE_FULLSCREEN) {
    gtk_window_unfullscreen(window);
  } else {
    gtk_window_fullscreen(window);
  }
  fl_method_call_respond_success(call, nullptr, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

static void load_bundled_window_icon() {
  // Resolve relative to the executable, not the caller's working directory.
  // The theme name remains registered for installed desktops and Wayland;
  // this pixbuf supplies the matching window icon for direct X11 launches.
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (!executable) return;
  g_autofree gchar* directory = g_path_get_dirname(executable);
  g_autofree gchar* icon_path =
      g_build_filename(directory, "data", APPLICATION_ID ".png", nullptr);
  g_autoptr(GError) error = nullptr;
  if (!gtk_window_set_default_icon_from_file(icon_path, &error)) {
    g_debug("Bundled window icon unavailable: %s", error->message);
  }
}

// GNOME integrates GTK header bars with its window controls. Other desktops,
// notably KDE Plasma on Wayland, are more reliable when the compositor draws
// the standard window decorations instead.
static gboolean desktop_prefers_header_bar() {
  const gchar* current_desktop = g_getenv("XDG_CURRENT_DESKTOP");
  if (current_desktop == nullptr) {
    return FALSE;
  }

  g_auto(GStrv) desktops = g_strsplit(current_desktop, ":", -1);
  for (gchar** desktop = desktops; *desktop != nullptr; ++desktop) {
    if (g_ascii_strcasecmp(*desktop, "GNOME") == 0) {
      return TRUE;
    }
  }

  return FALSE;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Keep GTK's client-side header bar on GNOME. On other desktops, use the
  // compositor-provided title bar so minimize, maximize, and close follow the
  // desktop theme and remain visible.
  gboolean use_header_bar = desktop_prefers_header_bar();
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    use_header_bar = g_strcmp0(wm_name, "GNOME Shell") == 0;
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "BStream Music");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "BStream Music");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_set_size_request(GTK_WIDGET(window), 960, 600);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->csv_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "bstream_music/incoming_csv", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->csv_channel, csv_method_call_cb,
                                           self, nullptr);
  g_autoptr(FlMethodChannel) window_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "bstream/desktop_window", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(window_channel, window_method_call_cb,
                                           view, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return FALSE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // Publish stable desktop metadata before media_kit/libmpv opens its first
  // audio stream. GTK forwards these values to PulseAudio/PipeWire, allowing
  // volume controls to show the application name and its XDG icon instead of
  // the executable and package defaults.
  g_set_application_name("BStream Music");
  gtk_window_set_default_icon_name(APPLICATION_ID);
  g_setenv("PULSE_PROP_application.name", "BStream Music", TRUE);
  g_setenv("PULSE_PROP_application.icon_name", APPLICATION_ID, TRUE);
  g_setenv("PULSE_PROP_media.role", "music", TRUE);
  // Fedora commonly uses mpv's native PipeWire backend instead of
  // pipewire-pulse. PIPEWIRE_PROPS is consumed by that backend and keeps the
  // stream metadata independent of the executable name.
  g_setenv(
      "PIPEWIRE_PROPS",
      "{ application.name = \"BStream Music\" application.icon-name = "
      "\"com.bstream.bstream_music\" application.id = "
      "\"com.bstream.bstream_music\" }",
      TRUE);

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  load_bundled_window_icon();
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->csv_channel);
  g_clear_pointer(&self->csv_pending, fl_value_unref);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->csv_pending = fl_value_new_list();
  self->csv_ready = FALSE;
  g_signal_connect(self, "command-line", G_CALLBACK(csv_command_line_cb), self);
  g_signal_connect(self, "open", G_CALLBACK(csv_open_cb), self);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_HANDLES_COMMAND_LINE |
                                         G_APPLICATION_HANDLES_OPEN,
                                     nullptr));
}
