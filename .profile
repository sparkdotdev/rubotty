# Heroku only. $HOME/.profile is sourced when a dyno boots, after the config
# vars and after every buildpack's .profile.d scripts, and before the process
# type's command runs. Nothing else in this repository reads it: the Coolify
# image built from railpack.json runs its command directly, and this file just
# rides along unused.
#
# WHY THIS EXISTS
#
# The apt buildpack puts lua5.4 in Aptfile under $HOME/.apt and exports PATH
# and LD_LIBRARY_PATH, which is enough for the sandbox to FIND lua5.4 but not
# enough for lua5.4 to find its modules: the interpreter's search path is
# compiled in and names /usr/share/lua/5.4, not the relocated copy of it. And
# there is no apt package for MessagePack at all on this stack (see Aptfile),
# so vendor/lua/MessagePack.lua ships in the repository instead, which lands
# at $HOME/vendor/lua on the dyno along with the rest of the checkout. Either
# way, without this file require("MessagePack") fails in the sandbox child and
# the scripting feature is dead on arrival with an error nobody sees until the
# first script runs.
#
# The trailing ";;" is Lua's own syntax for "and then the built in path", so
# these extend the defaults rather than replacing them. Dropping it would break
# any module that does ship in the image.
export LUA_PATH="$HOME/vendor/lua/?.lua;$HOME/.apt/usr/share/lua/5.4/?.lua;$HOME/.apt/usr/share/lua/5.4/?/init.lua;;"
export LUA_CPATH="$HOME/.apt/usr/lib/lua/5.4/?.so;$HOME/.apt/usr/lib/$(uname -m)-linux-gnu/lua/5.4/?.so;;"
