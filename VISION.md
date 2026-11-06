# Vision

DiceTower should make a real roll feel like a natural input to a digital game. Players keep the tactile experience of picking up, shaking, and throwing dice; the phone handles reading the result and preparing it for the game.

The long-term goal is support for common tabletop dice, including polyhedral and other marked dice, with reusable integrations for digital games. The first proof is deliberately focused: read a small group of pip-based d6 dice reliably in a controlled overhead tray.

## The experience we want

A player mounts an iPhone above a black-felt tray, checks its framing, and chooses how many dice to roll. The app watches the roll, waits for it to settle, and displays each face value and the total. The player sees which physical dice produced the answer and confirms it. If a die is hidden, cocked, unreadable, or missing, the app explains what needs attention.

The prototype must establish that this loop is dependable before adding game rules or unattended delivery. A convincing single-frame demonstration is useful, but a sequence of correctly handled rolls is the product.

## Principles

### Earn trust through visible evidence

Every proposed value should correspond to a visible die. The app must distinguish an observation from a confirmed result. A wrong but confident answer is more damaging than a request to separate dice and retry. Corrections must be easy and remain distinguishable from unmodified model output.

### Make the physical setup part of the system

The printed tray and holder provide repeatable framing, scale, lighting opportunities, and a known play area. Black felt reduces background distraction. Seeing the tray edges enables calibration and checks for camera movement. The prototype should exploit those constraints instead of attempting unrestricted tabletop vision immediately.

### Keep play local

Camera frames and inference stay on the phone during normal play. No account, server, or network connection is needed to recognize a roll. Saving or exporting images for training is a separate, explicit action.

### Learn from prior work with fresh evidence

Preserve useful labeled images, Core ML experiments, annotation conventions, and lessons about motion and tray boundaries. Re-measure them on this setup. Dataset quality, independent evaluation, and complete-roll behavior matter more than a historical training score.

### Build one coherent prototype

Use native iOS capture, inference, interface, and local history. Keep the recognition and roll-lifecycle components independent of individual game rules. Start with one model family and one supported setup; broaden them when measurements identify a reason.

## Boundaries of the first version

The MVP supports one to six opaque, light-colored pip d6 dice with visible, unobstructed upper faces, under diffuse indoor light in the fixed tray. Touching dice with separately visible tops belong in evaluation. Stacked, cocked, occluded, transparent, highly reflective, numbered, and other polyhedral dice may require a retry and are outside the initial recognition promise. Their presence must not intentionally be treated as a valid supported roll.

The MVP delivers confirmed values, a total, local history, and manual copy/share. It does not contain a game engine, remote camera streaming, an ESP32 subsystem, cloud inference, or a live game integration. It does not identify a physical die across rolls or certify randomness or fair play.

## What success means

On the actual printed rig, a player can complete repeated sessions without wondering whether the camera missed a die, whether a result is stale, or whether one roll was recorded twice. Most supported rolls produce the correct proposal promptly; uncertain scenes pause for help. Recognition remains responsive over sustained use, and measured results include rejected and failed rolls.

[MVP_DESIGN.md](MVP_DESIGN.md) defines the initial numerical gates. Those are targets to test, not claims about existing performance.

## Growth after the prototype

First expand supported d6 colors, sizes, and lighting through targeted data collection. Then add explicit, versioned game adapters and investigate partial rerolls and dice retained between turns. Broader dice types will require new labels, evaluation sets, and possibly different recognition models. Preserve the confirmed-roll interface so these changes can improve recognition without forcing each game to understand camera processing.
