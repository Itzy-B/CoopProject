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

## Images
<img width="463" height="400" alt="Invite" src="https://github.com/user-attachments/assets/3fc832fa-c836-49dc-85ab-b94789435f2d" />
<img width="533" height="158" alt="FriendPanel" src="https://github.com/user-attachments/assets/c4dcf931-3738-485d-b062-b6a6079edf3d" />
<img width="385" height="85" alt="Voip_Popup" src="https://github.com/user-attachments/assets/7bed2439-596d-4dce-8a01-736c2fa478f8" />
<img width="1267" height="725" alt="Lobby" src="https://github.com/user-attachments/assets/6ed3ef2a-c654-4aca-bf09-5cdd2c71c64c" />
<img width="672" height="1082" alt="FriendsLobby" src="https://github.com/user-attachments/assets/b2b36590-52b1-498a-83e2-e5a4bef2ffc0" />


