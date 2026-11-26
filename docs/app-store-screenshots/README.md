# App Store screenshots

The pictures for QBank's App Store record, taken from the app by `StoreScreenshotsUITests`. Do not edit them by hand: retake them.

## Retake them

After any change to a screen they show, on a Mac with the iOS simulator runtime:

```sh
test/store-screenshots.sh
```

It runs the test on a 6.9-inch iPhone and then a 13-inch iPad, one run-scoped simulator at a time through `test/sim.sh`, in light, with the status bar at 9:41 and the iPad set to Full Screen Apps. The three folders are replaced only when both runs pass. Look at every picture before committing it, and delete `.build/DerivedData` when you are done.

They show a free account's first launch with the sample set the app ships with, on the fake server and the fake store of the Debug launch seam: no real account, question or purchase. The order of choices, the exam's order and the times taken differ from one run to the next.

## What is here

App Store Connect shows each set in file name order.

| Folder | Size, portrait | Use |
|---|---|---|
| `iphone-6.9/` | 1320 x 2868 | the iPhone set |
| `ipad-13/` | 2064 x 2752 | the iPad set |
| `review/` | 1320 x 2868 | the review screenshot of each QBank Cloud subscription, not a store picture |

| File | Shows |
|---|---|
| `01-question` | a question with a diagram, a choice picked |
| `02-answer` | a checked answer with its rationale and key takeaway |
| `03-home` | Home with the sample set's topic; on iPad the topic is open beside the list |
| `04-topic` | the topic, with Exam, Review, Terms and its page. iPhone only |
| `05-result` | the result of the set |
| `06-review` | Review: what was missed, partly right or guessed |
| `07-exam` | a timed exam in progress |
| `cloud-plans` | the plans sheet: both plans, their periods and prices, the renewal terms, the policy links and Restore purchases |

## What the test checks

On every device it runs on, each picture is the whole screen, a PNG with no alpha channel, with no keyboard, and unlike every other picture of its set. When it writes the pictures out, the device's screen must be the size above, and the plans sheet must fit it whole. In the Mac check the iPad run is on a 13-inch iPad; the iPhone run there is on a smaller iPhone, which walks the same screens and checks them at its own size.
