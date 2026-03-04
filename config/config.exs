# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# Lunity editor mode: minimal ECSx manager for standalone editor runs.
# When using Lunity from a game project, the game's config sets its own manager.
config :ecsx, manager: Lunity.Editor.Manager

config :logger, level: :warning
