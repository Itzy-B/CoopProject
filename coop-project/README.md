# Steam Multiplayer Starter Project (Godot 4)

A free example project demonstrating Steam based co-op multiplayer in Godot. It uses **GodotSteam** and **SteamMultiplayerPeer** for peer-to-peer networking, with no dedicated server required.

## Features

- Up to **4 players**, with solo play supported.
- Steam friends list, invites, joinable lobbies, and party codes.
- Friends-only / invite-only party controls, plus host kick and invite management.
- Multiplayer player spawning and movement synchronization.
- Push-to-talk **proximity voice chat** and **radio chat**, including player muting.
- Example lobby menu, player controller, and waiting-area scene.

## Getting started

1. Open `project.godot` with **Godot 4.7** (the project is configured for 4.7).
2. Install and sign in to the **Steam desktop client**. The project includes the GodotSteam GDExtension under `addons/godotsteam/`.
3. Run the project. Press **Esc** to open the lobby menu, then hold **Create Lobby** to host. Other players can join through Steam friends/invites or a party code.
4. For your own Steam game, replace the test **AppID `480`** in `SteamManager` and **Project Settings → Steam**, and change `GAME_IDENTIFIER` in `scripts/networking/lobby_manager.gd` to a unique value shared by your builds.

## Demo controls

| Input | Action |
| --- | --- |
| WASD | Move |
| Mouse | Look around |
| Space | Jump |
| Esc | Lobby / menu |
| V (hold) | Proximity voice |
| B (hold) | Radio voice |

## Project structure

- `scripts/networking/` — Steam startup, lobby management, P2P sessions, and menu UI.
- `scripts/voip/` — Voice capture, relay, playback, and voice UI.
- `scripts/player/` — Example networked player controller.
- `scripts/main/` — Example player spawning and session scene setup.
- `scenes/` — Sample UI, player, and world scenes.

## Notes

This is a **starter/example project**, not a drop-in multiplayer solution for every game. The sample scenes and scripts are designed to work together; adapt spawning, replication, and UI to your own project. Multiplayer testing requires separate Steam accounts running the same project/build. AppID `480` is for development testing, not your published game's AppID.

GodotSteam is a third party dependency; see `addons/godotsteam/` for its own documentation and license.
