# Handmade Studio

Demo Version

https://github.com/user-attachments/assets/61e6200f-adee-4286-a54a-822f03c27004

# Disclosure

This project is currently in early stage of development and should be treated like a tech demo.
It can be extremely buggy and missing a lot of features.
Use at your own risk and do not rely on it whatsovever.

# Communication

- Join the Handmade Studio Discord server [here](https://discord.gg/VqTMRsaJ)
- Please feel free to open Github issues & discussions.

---

## Table of Contents

1. [Purpose](#purpose)
2. [What's different?](#whats-different)
3. [How do I build the demo?](#how-do-i-build-the-demo)
4. [I booted up a blank window, what do I do?](#i-booted-up-a-blank-window-what-do-i-do)
5. [Credits](#credits)

# Purpose

The purpose of this project is to develop the most powerful and intuitive GUI modal code editor that enhances the coding experience for developers.
This editor aims to combine the efficiency of modal editing with a user-friendly graphical interface,
providing a seamless and productive environment for writing, editing, and managing code, as well as project management & personal note-taking.
<br>
In the beginning, Handmade Studio will prioritize to optimize the development workflow for Zig developers.

---

# What's Different?

### Canvas based

<img src="https://github.com/user-attachments/assets/166bc785-fdb7-4519-a5b9-0b7ad1a51e4b" alt="Screenshot from 2024-12-26 23-45-43" width="500"/>

Handmade Studio lets the user operates on an infinite canvas, which:

- Enables view operations like pan & zoom.
- Enables taking notes on top of / right alongside code files. (NOT YET)

### Dynamic Font Sizes & Font Faces

<img src="https://github.com/user-attachments/assets/fd329ee8-0ed3-4b50-a1ba-99abd318edd1" alt="Screenshot from 2024-12-26 23-45-43" width="500"/>

Planned features:

- Toggle-able syntax-based font sizes & font faces. (CURRENTLY HARD CODED, NOT TOGGLE-ABLE YET)
- Windows can have different styles from each other. (NOT YET)

### Images (NOT YET)

Planned features:

- Images on the canvas for note taking purposes. (NOT YET)
- Images to annotate LSP Diagnostics. (NO LSP YET)
- Images to annotate jobs / test results. (NOT YET)

### Inputs

Handmade Studio will leverage `Key Combos`, in addition to `Key Chords` like other modal editors.

#### What's a "Key Combo"?

Already exist in other editors:

- `Ctrl -> C` is a key combo
- `Ctrl -> Shift -> C` is a key combo

With HS you can add combos like:

- `Z -> J` (hold down Z, then press J)
- `Z -> X -> J` (hold down Z, hold down X, then press J)

### Canvas-based note-taking (NOT YET)

Like Excalidraw / Obsidian canvas

---

# How do I build the Demo?

1. Clone the repo.
2. `git submodule update --init --recursive`.
3. `zig build run` or `zig build run --release=fast`.

# I booted up a blank window, what do I do?

- Press `Ctrl+F` to bring up a Fuzzy Finder.
- Search for `main.zig`.
- To pan, either hold down right mouse button and drag, or hold down `Z` -> `h` / `j` / `k` / `l`.
- To zoom, either use the mouse scroll wheel or hold down `Z` -> `X` -> `h` / `j` .
- Look at `main.zig` for more mappings you can try out.
- Try out basic Vim movements & editing.

---

# Credits

Thanks to [@neurocyte](https://github.com/neurocyte/) for making [Flow Control](https://github.com/neurocyte/flow).
<br>
I started learning Zig & began this project 6 months ago. From his hard work & directions, I was able to:

- Install, setup & build Tree Sitter in Zig.
- Learn, copy & modify his Rope data structure implementation.
- Learn the general structure of a text editor and how to write one.
