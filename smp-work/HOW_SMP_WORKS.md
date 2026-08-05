# How SMP works, and what LapZero actually does about it

## The problem with triple screens

If you run three monitors in iRacing, you turn on "Render Scene Using 3
Projections". Without it, the game stretches one wide camera across all
three screens and everything at the edges looks wrong. With it, you get
three separate cameras, each pointed correctly at its own screen, and the
geometry lines up.

The cost is that the game now draws the scene three times. Every tree, every
kerb, every car ahead of you, submitted to the GPU once per screen. The
pixels genuinely are different on each screen, so some of that work is
unavoidable. But a lot of it is not. Working out where a vertex sits in the
world, what it is attached to, which texture it uses: that is identical for
all three views. Doing it three times is waste.

## What NVIDIA built

NVIDIA's answer is a hardware feature. On Pascal it was Single Pass Stereo,
which handled two views for VR headsets. On Turing and later it became
Multi-View Rendering, which handles up to four views with completely
independent cameras. That is the one that matters for triple screens.

The idea is simple. The game submits its geometry once. The vertex shader,
instead of producing one screen position per vertex, produces four. The
hardware then takes that single stream of geometry and expands it across the
views for you, for free, in silicon. All the shared work happens once. Only
the genuinely per-view work happens per view.

NVIDIA quotes something like a 20 to 25% gain from this.

## How iRacing uses it

iRacing is the only game I have been able to find that uses this API for
triple screens. I have had hints that two or three other titles use it at
all, but I have not been able to identify them, and the ones NVIDIA
documents are VR cases.

When you turn the SMP toggle on, iRacing does three things.

It calls `NvAPI_D3D_SetMultiViewMode` and asks for four views with
independent viewport masks. Four, not three, because four is the API's
maximum and the feature is defined in terms of four. It compiles against the
maximum and masks off whatever the current setup does not need, so on three
screens the fourth view is switched off.

It compiles its vertex shaders through NVIDIA's own shader creation calls
rather than Direct3D's, so it can attach custom output semantics. The
shaders come out writing `SV_POSITION` for view 0 plus
`NV_POSITION_VIEW_1`, `_2` and `_3` for the others, and two viewport mask
registers that say which screen each view belongs on.

Then it stops drawing the scene three times and draws it once.

That last part is the whole point, and it is worth being clear about it.
The toggle does not just switch on an optimisation inside the driver. It
changes how iRacing itself submits work. With the toggle off, three passes.
With it on, one. The game has already committed to the single pass before
the GPU sees anything, which is why a half-working implementation shows you
a broken picture rather than a slow one.

## Why none of this worked on Linux

DXVK translates Direct3D 11 into Vulkan. dxvk-nvapi handles the NVIDIA API
calls that games make outside Direct3D.

Neither of them knew what to do with any of the above. dxvk-nvapi accepted
the multi-view calls and quietly did nothing with them. DXVK had never heard
of the custom semantics, so the extra positions and the viewport masks were
compiled away as unused outputs.

Before any of this work, the toggle could not even be switched on. iRacing
asks the driver whether multi-view is supported, and on Linux the answer was
no, so the option was unavailable and that was the end of it.

Once I got far enough for iRacing to accept the toggle, what happened was
this: the game switched to one pass, handed over four positions per vertex,
and Linux drew one of them onto one screen. The other two screens showed sky.
As far as I know I am the first person to see that, because I am the first
person to get the toggle to turn on at all.

## What LapZero does

The job is to take what iRacing hands over and turn it into something Vulkan
can actually execute.

dxvk-nvapi now forwards the multi-view calls into DXVK instead of dropping
them, and passes along the custom semantic list when shaders are created.
DXVK reads the vertex shader's output signature, finds which registers carry
the per-view positions and the viewport masks, and remembers them.

Then, when the game binds one of those vertex shaders, DXVK builds a
geometry shader that does not exist anywhere in iRacing's files. It is
synthesised on the spot. That shader runs four times per triangle. On each
run it picks the matching position out of the four the vertex shader
produced, tags the triangle with the right screen, and emits it.

So the one stream of geometry iRacing submits gets fanned out into three
correct views, which is exactly what the hardware feature was supposed to do
for us.

There was a fair amount of pain getting there. The most stubborn bug turned
out to be that the synthesised shader was reading its inputs from the wrong
places, because it numbered them differently to how the vertex shader had.
It was reading a viewport mask constant as if it were a camera position.
That produced a picture where bits of the left screen appeared on the middle
and right, and the left screen showed nothing at all, which took a while to
untangle.

## Does it work

Yes. Same replay, same camera, paused, toggled off and on:

|                   | SMP off | SMP on |
| ----------------- | ------- | ------ |
| FPS               | 151     | 222    |
| Draw calls        | 2858    | 1261   |
| Queue submissions | 19      | 12     |
| GPU load          | 36%     | 55%    |

Draw calls drop to about 46% of what they were. That is not a clean
three-into-one, and it should not be: only the scene geometry goes through
SMP. The interface, the mirrors, shadows and the post-processing all still
draw once each regardless of how many screens you have, so they are unchanged
either way. The scene part collapses three into one and everything else stays
put, which nets out at a bit under half.

The frame rate goes up by about 45%.

GPU load going up is not a mistake. The GPU was sitting idle waiting for
work to be handed to it, and now it is being fed properly.

Visually it is identical. Two screenshots of the same paused frame with the
toggle off and on are indistinguishable, which is the correct result. SMP is
meant to be a faster way of drawing the same thing, not a different thing.

## Why the gain is bigger than NVIDIA's number

NVIDIA quote 20 to 25%. I am seeing 45%. I do not know for certain why.

The explanation that makes sense to me is that on Windows the path from a
draw call to the GPU is already short, so removing draw calls saves less. On
Linux every one of those calls goes through DXVK's translation and its
command stream before it reaches Vulkan, which is a longer path, so removing
them saves more. More overhead to remove in the first place.

That is a guess that fits the numbers, not something I have proved. If
somebody has a better explanation I would like to hear it. Failing that I am
going to claim I have accidentally introduced a second bug to iRacing that
inexplicably makes it faster, and see whether anyone notices.

Either way it is not Linux beating Windows at anything. It is Linux finally
getting a feature it never had, and getting a decent chunk of it.

Worth adding that these are figures from one replay at one camera position on
one machine. More scenes needed before anyone should quote them as gospel.

## What is left

The viewport masks are read but not yet acted on. iRacing tells us which
screen each view belongs to, and at three screens it tells us the fourth
view should not be drawn at all. Right now we draw it anyway. It produces
nothing visible, because iRacing also collapses that view's geometry to
nothing, but it is a quarter of the geometry work being done for no reason.
That is the next change and it is small.

After that is the bigger one, and it is where I get stuck.

Everything above still does the fan-out in a shader. That is software doing a
job the hardware has dedicated silicon for. Every NVIDIA card from Turing
onwards can do it natively: the RTX 20 and GTX 16 series, RTX 30, RTX 40, and
the RTX 50 series. Pascal, the GTX 10 series, has an earlier two-view version
of the same thing.

The obvious answer is to use that silicon, and Vulkan does expose it, through
an extension called `VK_NVX_multiview_per_view_attributes`. My card supports
it. So does every card listed above. But it does not fit what iRacing does,
and the reason is worth explaining because it is the whole problem.

### Why the hardware path does not fit

iRacing draws all three screens into **one image**, side by side, with each
camera writing to its own third of that image.

Vulkan's version of the same feature insists that each camera writes to its
own separate **layer** of the image, like pages in a stack rather than
sections of one page. That is not optional; the spec enforces it, and
iRacing's images only ever have one layer.

There is another Vulkan extension that does work on a single layer, but it
can only broadcast: it sends the same triangle to several parts of the image
at once. Triple screens need three genuinely different pictures, because each
screen has its own camera angle, so broadcasting the same one is no use.

So one option gives you different cameras but forces separate layers, and the
other keeps one layer but only copies the same picture. Neither does both.
The hardware manages it fine; Windows asks for it through NVAPI and gets it.
Vulkan just never gave anyone a way to ask.

The extension that would need changing was written in January 2017 for VR
headsets, where one layer per eye made perfect sense, and nothing has been
done to it since. I am going to raise it as an issue with Khronos and NVIDIA
and see what happens, though I would not bet on it, given how few games use
this at all.

### Where I stop

I am not clever enough to take it further than this, and I am not going to
pretend otherwise. Working out what iRacing was asking for and getting Linux
to answer it was about my limit, and a fair chunk of that came from thinking
out loud with an AI until the shape of the problem got clear enough to test.

What I hope is that the work gets accepted upstream so it is in everyone's
DXVK rather than my custom build, and that somebody sharper than me picks up
the hardware path from here. It is all written down, the captures are saved,
and I will help anyone who wants to take it on.

## The point of all this

None of this makes iRacing playable online, because the anticheat still does
not permit Linux. What it does is remove one more excuse. "Triple screens
need SMP and SMP does not work on Linux" was a real gap, and it is closed.

The list of things iRacing does that Linux does not support is getting short.

Which raises a question I would genuinely like answered: **is there anything
left?** If you know of something iRacing does that still does not work on
Linux, tell me. I would rather find out now than have it come up as a reason
to say no later.
