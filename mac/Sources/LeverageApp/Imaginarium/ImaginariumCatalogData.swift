// The Imaginarium's prompt catalog (PRD FR-026 to FR-029), compiled into the
// app as JSON so that it needs no resource bundle. Edit the JSON below; the
// tests in ImaginariumCatalogTests check every entry (FR-028). Raise
// "version" whenever an entry is added, removed or reworded (FR-026).

enum ImaginariumCatalogData {
    static let json = ##"""
{
  "version": 1,
  "categories": [
    {
      "id": "pictures",
      "name": "Pictures"
    },
    {
      "id": "websites",
      "name": "Websites"
    },
    {
      "id": "apps",
      "name": "Apps"
    },
    {
      "id": "games",
      "name": "Games"
    },
    {
      "id": "automations",
      "name": "Automations"
    },
    {
      "id": "gifts",
      "name": "Gifts"
    },
    {
      "id": "learning",
      "name": "Learning"
    },
    {
      "id": "home",
      "name": "Home and life"
    }
  ],
  "entries": [
    {
      "id": "storybook-pet-portrait",
      "category": "pictures",
      "title": "Storybook pet portrait",
      "description": "Your pet as the hero of a watercolor picture book.",
      "minutes": 5,
      "fills": [
        {
          "key": "pet",
          "label": "Your pet",
          "default": "Biscuit, a corgi"
        },
        {
          "key": "scene",
          "label": "The adventure",
          "default": "sailing a teacup boat across a pond"
        }
      ],
      "prompt": "Create a children’s picture-book illustration of {pet} {scene}.\n\nStyle: loose watercolor washes, soft ink outlines, warm morning light, gentle paper texture, lots of white space around the hero. Square, no text in the image.\n\nSave it as storybook-1.png, then make storybook-2.png from a different camera angle.",
      "done_when": [
        "Two square PNG images are saved in the project folder",
        "The pet and the scene match the description",
        "Neither image has text or a watermark"
      ],
      "needs": [
        "image_tool"
      ]
    },
    {
      "id": "neon-synthwave-poster",
      "category": "pictures",
      "title": "Neon synthwave poster",
      "description": "A retro 80s poster of any place, glowing grid and all.",
      "minutes": 5,
      "fills": [
        {
          "key": "place",
          "label": "Place",
          "default": "Phoenix at dusk"
        },
        {
          "key": "headline",
          "label": "Headline",
          "default": "DESERT NIGHTS"
        }
      ],
      "prompt": "Create a retro 1980s synthwave poster of {place}.\n\nNeon magenta and cyan, a chrome headline that reads \"{headline}\", a glowing perspective grid floor, a big striped sunset sun and faint VHS grain. Portrait 2:3, 3000px tall so it prints well.\n\nSave poster.png and a copy without the headline.",
      "done_when": [
        "poster.png is 2:3 and at least 3000px tall",
        "The headline is spelled exactly as given",
        "A second copy without the headline is saved"
      ],
      "needs": [
        "image_tool"
      ]
    },
    {
      "id": "tiny-clay-world",
      "category": "pictures",
      "title": "Tiny clay world",
      "description": "Your hobby or your room as a little handmade clay diorama.",
      "minutes": 5,
      "fills": [
        {
          "key": "subject",
          "label": "What to model",
          "default": "my cozy attic pottery studio"
        },
        {
          "key": "palette",
          "label": "Colors",
          "default": "terracotta, sage green and butter yellow"
        }
      ],
      "prompt": "Create a picture of {subject} as a tiny stop-motion-style clay diorama.\n\nEverything looks hand-modelled from soft modelling clay: visible thumbprints, slightly lopsided shapes, tiny rolled-clay plants and furniture, a few small figures busy at work. Color scheme: {palette}. Shot from a slightly raised angle with a shallow depth of field, warm studio lighting and a soft shadow on a plain tabletop.\n\nMake it landscape 3:2, with no text or logos in the image. Save it as clay-world.png, then make clay-world-close.png as a close-up of one corner of the scene.",
      "done_when": [
        "Two PNG images are saved in the project folder",
        "The scene matches the subject and the color scheme",
        "The materials look like clay and neither image has text or logos"
      ],
      "needs": [
        "image_tool"
      ]
    },
    {
      "id": "field-guide-plate",
      "category": "pictures",
      "title": "Field guide plate",
      "description": "A vintage botanical-style plate of anything, labelled in Latin.",
      "minutes": 5,
      "fills": [
        {
          "key": "subject",
          "label": "Subject",
          "default": "the common garden snail"
        },
        {
          "key": "caption",
          "label": "Plate title",
          "default": "Plate IV: Gastropods of the Kitchen Garden"
        }
      ],
      "prompt": "Create a vintage natural-history field guide plate showing {subject}.\n\nStyle: fine pen-and-ink linework with delicate hand-colored watercolor, on aged cream paper with faint foxing. Show the subject from three angles plus one detail close-up, each with a thin leader line to a small hand-lettered label in Latin-style binomial naming. Add a numbered key along the bottom and the title \"{caption}\" in an engraved serif at the top.\n\nPortrait 3:4, 2400px tall. Save it as plate.png. Keep the labels legible, and use invented Latin-sounding names if the real ones are unknown.",
      "done_when": [
        "plate.png is portrait 3:4 and at least 2400px tall",
        "The title is spelled exactly as given",
        "The plate has at least four labelled views with leader lines"
      ],
      "needs": [
        "image_tool"
      ]
    },
    {
      "id": "glass-portfolio",
      "category": "websites",
      "title": "Glass portfolio",
      "description": "A one-page portfolio with frosted glass and drifting color.",
      "minutes": 25,
      "fills": [
        {
          "key": "name",
          "label": "Your name",
          "default": "Alex Rivera"
        },
        {
          "key": "what",
          "label": "What you do",
          "default": "product designer"
        },
        {
          "key": "hue",
          "label": "Color mood",
          "default": "sunset pink and violet"
        }
      ],
      "prompt": "Build a one-page portfolio site for {name}, a {what}.\n\nLook: frosted-glass cards over slowly drifting {hue} gradient blobs, a big confident headline, generous spacing.\nSections: hero, selected work (6 project cards with placeholder images), about, contact links.\n\nPlain HTML, CSS and a little JavaScript; it opens straight from index.html with no build step. Readable at phone width, every text passes WCAG AA contrast, and animation stops when the visitor prefers reduced motion.",
      "done_when": [
        "index.html opens in a browser with no build step",
        "All four sections work at 375px wide",
        "Animation stops when reduced motion is on"
      ],
      "needs": []
    },
    {
      "id": "loud-launch-page",
      "category": "websites",
      "title": "Loud launch page",
      "description": "A bold, brutalist landing page for your product or idea.",
      "minutes": 30,
      "fills": [
        {
          "key": "product",
          "label": "Product or idea",
          "default": "a plant-watering reminder"
        },
        {
          "key": "cta",
          "label": "Main button",
          "default": "Join the waitlist"
        }
      ],
      "prompt": "Design and build a brutalist landing page for {product}.\n\nThick black borders, oversized type, one shocking accent color, hard drop shadows and a deliberately raw grid. Sections: headline with a \"{cta}\" button, three feature blocks, an FAQ and a footer.\n\nThe button opens an email form that saves sign-ups to a local JSON file through a tiny local server. Add a README with the one command that runs it.",
      "done_when": [
        "The page runs locally with the one command in the README",
        "A submitted email lands in the local JSON file",
        "The layout holds together at phone width"
      ],
      "needs": []
    },
    {
      "id": "party-rsvp-site",
      "category": "websites",
      "title": "Party RSVP site",
      "description": "A festive event page where friends say yes, no or maybe.",
      "minutes": 35,
      "fills": [
        {
          "key": "event",
          "label": "Event",
          "default": "Maya’s 30th birthday"
        },
        {
          "key": "when",
          "label": "When and where",
          "default": "June 14, the rooftop on Pine St"
        },
        {
          "key": "vibe",
          "label": "Vibe",
          "default": "disco glitter"
        }
      ],
      "prompt": "Build a festive one-page site for {event}, {when}.\n\nTheme: {vibe}, with a playful animated header and a live countdown. Guests RSVP with their name, yes / no / maybe, plus-ones and a note. Store answers in a local SQLite file and list them on a host-only page at /host.\n\nInclude a README that explains how to run it.",
      "done_when": [
        "The countdown shows the right time left",
        "A new RSVP shows on /host",
        "The README explains how to run it"
      ],
      "needs": []
    },
    {
      "id": "link-in-bio-page",
      "category": "websites",
      "title": "Link-in-bio page",
      "description": "All your links on one animated page, in your colors.",
      "minutes": 20,
      "fills": [
        {
          "key": "name",
          "label": "Name or handle",
          "default": "@juniper.makes"
        },
        {
          "key": "links",
          "label": "Your links",
          "default": "my shop, my newsletter, my latest video, email me"
        },
        {
          "key": "colors",
          "label": "Colors",
          "default": "deep teal, coral and cream"
        }
      ],
      "prompt": "Build a single-page link-in-bio site for {name}.\n\nShow a round avatar placeholder, a short tagline, and one big tappable button for each of these links: {links}. Colors: {colors}. Give the buttons a gentle entrance animation, a lively hover and press state, and a slow animated background. Make the link addresses easy to edit in one clearly marked list at the top of the file.\n\nPlain HTML, CSS and a little JavaScript, opened straight from index.html with no build step. It must look right on a phone, work with the keyboard, keep text contrast at WCAG AA, and stop animating when the visitor prefers reduced motion.",
      "done_when": [
        "index.html opens in a browser with no build step",
        "Every link has its own button and the list is easy to edit",
        "Animation stops when reduced motion is on"
      ],
      "needs": []
    },
    {
      "id": "pocket-to-do",
      "category": "apps",
      "title": "Pocket to-do",
      "description": "A calm to-do app that lives on your Mac, with no account and no cloud.",
      "minutes": 40,
      "fills": [
        {
          "key": "look",
          "label": "Look",
          "default": "a paper notebook with soft grain"
        },
        {
          "key": "extras",
          "label": "Extras",
          "default": "tags, due dates and a Today view"
        }
      ],
      "prompt": "Build a local to-do app styled like {look}.\n\nFeatures: add, edit, complete and delete tasks; {extras}; keyboard shortcuts N (new) and Space (complete). Save everything in a local SQLite file so it survives restarts.\n\nIt runs with one command and opens in the browser. Include tests for creating, completing and filtering tasks.",
      "done_when": [
        "Tasks are still there after the app restarts",
        "The N and Space shortcuts work",
        "Tests pass with the command in the README"
      ],
      "needs": []
    },
    {
      "id": "habit-streaks",
      "category": "apps",
      "title": "Habit streaks",
      "description": "Tick off habits and watch a glowing streak map fill in.",
      "minutes": 35,
      "fills": [
        {
          "key": "habits",
          "label": "Your habits",
          "default": "read 20 minutes, walk, no phone after 10pm"
        }
      ],
      "prompt": "Build a local habit tracker for: {habits}.\n\nOne tap marks a habit done today. Each habit gets a year-long heatmap with a neon gradient, its current and longest streak, and there is a weekly summary. Data lives in local SQLite and exports to CSV.\n\nRuns with one command.",
      "done_when": [
        "Marking a habit done updates its streak",
        "The heatmap shows a full year",
        "CSV export opens in a spreadsheet"
      ],
      "needs": []
    },
    {
      "id": "budget-jars",
      "category": "apps",
      "title": "Budget jars",
      "description": "Drop in a bank CSV and get a friendly picture of your spending, offline.",
      "minutes": 45,
      "fills": [
        {
          "key": "jars",
          "label": "Your jars",
          "default": "rent, food, fun, savings"
        },
        {
          "key": "currency",
          "label": "Currency",
          "default": "USD"
        }
      ],
      "prompt": "Build an offline budgeting app.\n\nI import a bank CSV; it guesses each row’s jar ({jars}), lets me fix the guesses and remembers my fixes next time. Show monthly totals per jar in {currency}, a simple trend chart, and which jars went over.\n\nAll data stays on this Mac. The app makes no network calls.",
      "done_when": [
        "Importing the sample CSV fills every jar",
        "A corrected jar is remembered on the next import",
        "The app makes no network requests"
      ],
      "needs": []
    },
    {
      "id": "recipe-box",
      "category": "apps",
      "title": "Recipe box",
      "description": "Save recipes, scale the servings and build a grocery list.",
      "minutes": 40,
      "fills": [
        {
          "key": "cuisine",
          "label": "Starter recipes",
          "default": "six cozy weeknight dinners"
        },
        {
          "key": "look",
          "label": "Look",
          "default": "a worn kitchen index card with handwriting-style headings"
        }
      ],
      "prompt": "Build a local recipe box app styled like {look}.\n\nStart it with {cuisine} so it is never empty. Each recipe has a title, ingredients with amounts and units, steps, tags and a photo slot. Let me add, edit, search and tag recipes. A servings control rescales every amount and turns decimals into friendly fractions such as 1 1/2 cups.\n\nLet me tick recipes to cook this week and press one button to get a single grocery list that merges matching ingredients, grouped by aisle, which I can check off and print. Save everything in a local SQLite file.\n\nIt runs with one command and opens in the browser. Include tests for scaling and for merging the grocery list.",
      "done_when": [
        "Changing servings rescales every ingredient correctly",
        "Two recipes that share an ingredient give one merged grocery line",
        "Recipes are still there after the app restarts"
      ],
      "needs": []
    },
    {
      "id": "pet-runner",
      "category": "games",
      "title": "Pet runner",
      "description": "An endless runner game starring your pet.",
      "minutes": 30,
      "fills": [
        {
          "key": "hero",
          "label": "Hero",
          "default": "a corgi in a red scarf"
        },
        {
          "key": "world",
          "label": "World",
          "default": "a candy forest"
        }
      ],
      "prompt": "Make an original endless-runner browser game starring {hero} running through {world}.\n\nJump with Space or a tap, collect treats, dodge obstacles; the speed rises slowly. Draw all the art in code, keep a score and a best score saved in the browser, and add a pause button.\n\nOne HTML file.",
      "done_when": [
        "The game is one HTML file that opens in a browser",
        "The best score is kept after a reload",
        "It plays with the keyboard and with touch"
      ],
      "needs": []
    },
    {
      "id": "word-garden",
      "category": "games",
      "title": "Word garden",
      "description": "A daily word puzzle you host for your family.",
      "minutes": 30,
      "fills": [
        {
          "key": "family",
          "label": "Players",
          "default": "the Okafor family"
        },
        {
          "key": "words",
          "label": "Word theme",
          "default": "everyday words from the kitchen and garden"
        },
        {
          "key": "look",
          "label": "Look",
          "default": "a sunny greenhouse with climbing vines"
        }
      ],
      "prompt": "Build an original daily word puzzle for {family}, styled like {look}.\n\nInvent your own rules, not a copy of any existing word game. Suggested rules: each day there is one hidden five-letter word from the theme: {words}. A player gets six guesses. After each guess, every letter is shown as a seedling (right letter, right place), a bud (right letter, wrong place) or bare soil (not in the word), and the colors are paired with shapes so color is never the only clue. A solved puzzle grows a flower in the garden.\n\nThe word for each day comes from a plain text list the host can edit, picked by the date so everyone gets the same puzzle. Keep a shared leaderboard and each player’s streak in a local file, and reject guesses that are not in a bundled word list.\n\nIt runs with one command from a README and can be opened by other devices on the same Wi-Fi. It works with the keyboard and with touch.",
      "done_when": [
        "Everyone who opens it on the same day gets the same word",
        "Feedback uses shapes as well as colors",
        "Streaks and the leaderboard survive a restart"
      ],
      "needs": []
    },
    {
      "id": "trivia-night-host",
      "category": "games",
      "title": "Trivia night host",
      "description": "A quiz show on your TV, with friends buzzing in from their phones.",
      "minutes": 45,
      "fills": [
        {
          "key": "topic",
          "label": "Quiz topic",
          "default": "movies from the 90s, local history and food"
        },
        {
          "key": "host",
          "label": "Show name",
          "default": "Friday Night Brain Trust"
        },
        {
          "key": "rounds",
          "label": "Rounds",
          "default": "3 rounds of 8 questions"
        }
      ],
      "prompt": "Build a local trivia show called {host} that I put on the TV and my friends play from their phones.\n\nA host screen, shown full screen on the TV, displays the question, a countdown, the buzz-in order and a live scoreboard. Each player opens a short link on their phone, enters a nickname, and gets a big buzz button, and later the multiple-choice answers. Quiz setup: {rounds}, on the topic: {topic}. Write the questions yourself and store them in an editable file, with a few bonus questions in case of ties.\n\nThe host controls the show from a keyboard or a second page: next question, reveal the answer, award points, undo. Use a small local server that other devices on the same Wi-Fi can reach, and show the address and a QR code on the TV for joining. Nothing leaves the house network, and no sign-in is needed.\n\nUse big type and high contrast so it reads from a sofa, make sure it works in the common phone browsers, and add a README with the one command that starts the show.",
      "done_when": [
        "The one command in the README starts the show",
        "A phone on the same Wi-Fi can join and buzz in",
        "The scoreboard updates when the host awards points"
      ],
      "needs": []
    },
    {
      "id": "menu-bar-pet",
      "category": "games",
      "title": "Menu bar pet",
      "description": "A tiny creature that lives in your menu bar and needs feeding.",
      "minutes": 40,
      "fills": [
        {
          "key": "creature",
          "label": "Creature",
          "default": "a sleepy moss-green dragon"
        },
        {
          "key": "name",
          "label": "Its name",
          "default": "Pebble"
        },
        {
          "key": "snack",
          "label": "Favorite snack",
          "default": "blueberries"
        }
      ],
      "prompt": "Build a native macOS menu bar app in Swift and SwiftUI: a tiny virtual pet, {creature} named {name}, that lives in the menu bar.\n\nThe menu bar icon shows its mood with a small drawn face. Clicking it opens a popover with hunger, happiness and energy meters and three actions: feed ({snack}), play and rest. The meters drift down slowly over real time, even while the Mac was asleep, and it gets sleepy at night. Draw all the art in code, with no image files needed.\n\nIt never punishes the owner: if it is neglected it just gets sleepy and quiet, and a gentle reminder says it would like a snack. Save its state in a local file so it carries on after the app restarts. Notifications are optional and off until the owner turns them on. Honor Reduce Motion, and make the popover work with VoiceOver.\n\nMake it buildable with one command from the README, for example swift build or a small build script that produces a .app, with no paid developer account needed.",
      "done_when": [
        "The README command builds an app that shows an icon in the menu bar",
        "Feeding it raises the hunger meter and the icon mood changes",
        "Its state is still there after quitting and reopening"
      ],
      "needs": []
    },
    {
      "id": "downloads-tidy-up",
      "category": "automations",
      "title": "Downloads tidy-up",
      "description": "Sorts a messy folder, and shows you the plan before it moves a thing.",
      "minutes": 15,
      "fills": [
        {
          "key": "folder",
          "label": "Folder",
          "default": "~/Downloads"
        },
        {
          "key": "rule",
          "label": "Sort by",
          "default": "file type, then month"
        }
      ],
      "prompt": "Write a script that organizes {folder} into folders by {rule}.\n\nBy default it does a dry run and prints exactly what it would move; it only moves files with --apply.\n\nIt never deletes anything, skips files changed in the last hour, and writes an undo log so one command puts everything back.",
      "done_when": [
        "A dry run moves nothing and lists every planned move",
        "--apply moves files exactly as listed",
        "The undo command restores the original layout"
      ],
      "needs": []
    },
    {
      "id": "photo-renamer",
      "category": "automations",
      "title": "Photo renamer",
      "description": "Renames photos by date and place from their metadata, with undo.",
      "minutes": 20,
      "fills": [
        {
          "key": "folder",
          "label": "Photo folder",
          "default": "~/Pictures/Camera Roll"
        },
        {
          "key": "pattern",
          "label": "Name pattern",
          "default": "2025-06-14 Lisbon 001"
        }
      ],
      "prompt": "Write a script that renames the photos in {folder} using the date and place stored in each photo’s metadata, in the pattern {pattern}.\n\nRead the capture date and any GPS position from the file’s own metadata, with no network. For the place, use a city or location name if the metadata already holds one; otherwise match the GPS position against a small editable places.csv next to the script that maps a name to a latitude, longitude and radius, and leave the place out when nothing matches. Number photos that share a date and place in order of time, and handle files with no date by leaving them alone and listing them.\n\nBy default it does a dry run and prints every rename it would do; it only renames with --apply. It never overwrites a file, skips non-photos, and writes an undo log so one command restores every original name.\n\nInclude a README with the commands, and a few tests that use sample files.",
      "done_when": [
        "A dry run renames nothing and lists every planned rename",
        "--apply renames exactly as listed and never overwrites a file",
        "The undo command restores every original name"
      ],
      "needs": []
    },
    {
      "id": "receipt-sorter",
      "category": "automations",
      "title": "Receipt sorter",
      "description": "Reads PDF receipts in a folder and fills a spreadsheet for taxes.",
      "minutes": 25,
      "fills": [
        {
          "key": "folder",
          "label": "Receipts folder",
          "default": "~/Documents/Receipts"
        },
        {
          "key": "columns",
          "label": "Columns",
          "default": "date, vendor, total, tax, category"
        }
      ],
      "prompt": "Write a script that reads every PDF receipt in {folder} and writes a CSV with the columns: {columns}, plus the file name.\n\nEverything stays on this Mac. Read the PDF’s own text; for scanned receipts use the text recognition built into macOS, and never send a file anywhere. Guess the category from the vendor using a small rules file the owner can edit, and remember each correction the owner makes.\n\nWhen a field cannot be found with confidence, leave it empty and mark the row as needing review rather than guessing. Never change or move the PDFs. Running it again should add only new receipts, not duplicates, and it should print a short summary with the grand total per category.\n\nAdd a README with one command to run it and a few sample receipts for the tests.",
      "done_when": [
        "Every sample receipt produces one CSV row with the right total",
        "Unreadable fields are flagged for review instead of guessed",
        "Running it twice does not create duplicate rows"
      ],
      "needs": []
    },
    {
      "id": "weekly-folder-digest",
      "category": "automations",
      "title": "Weekly folder digest",
      "description": "A one-page summary of what changed in your chosen folders.",
      "minutes": 20,
      "fills": [
        {
          "key": "folders",
          "label": "Folders",
          "default": "~/Documents/Work, ~/Desktop"
        },
        {
          "key": "days",
          "label": "Look back",
          "default": "7 days"
        }
      ],
      "prompt": "Write a script that looks at these folders: {folders}, and builds a one-page summary of what changed in the last {days}.\n\nThe page lists new files, edited files and deleted files per folder, the biggest files, and any large files that were not opened for a long time. Include totals up top, group by day, and make the page easy to read and print. Save it as a dated HTML file and open it when it finishes. The script only reads: it never changes, moves or deletes anything in those folders.\n\nKeep a small local snapshot between runs so deleted files can be noticed. Run it on demand with one command, and also add a clearly explained optional step that installs a local weekly schedule with launchd, plus a command to remove it again.\n\nAdd a README and a few tests that use a temporary folder.",
      "done_when": [
        "The summary page lists new, edited and deleted files from the test folder",
        "The script changes nothing in the watched folders",
        "The README explains how to install and remove the weekly schedule"
      ],
      "needs": []
    },
    {
      "id": "birthday-time-capsule",
      "category": "gifts",
      "title": "Birthday time capsule",
      "description": "A heartfelt microsite full of memories for someone you love.",
      "minutes": 30,
      "fills": [
        {
          "key": "who",
          "label": "For",
          "default": "Grandma Rosa, turning 80"
        },
        {
          "key": "memories",
          "label": "Memories",
          "default": "her garden, Sunday pancakes, the 1972 road trip"
        }
      ],
      "prompt": "Create a heartfelt one-page birthday site for {who}.\n\nScrapbook style: taped photo placeholders, handwritten-style headings and gentle confetti on load. One section per memory: {memories}. Add a guestbook that saves notes to a local file and a big closing message.\n\nIt should print cleanly as a keepsake PDF.",
      "done_when": [
        "Every memory has its own section",
        "A guestbook note is saved and shown",
        "Printing to PDF keeps the layout"
      ],
      "needs": []
    },
    {
      "id": "inside-joke-crossword",
      "category": "gifts",
      "title": "Inside-joke crossword",
      "description": "A printable crossword made from your own clues.",
      "minutes": 25,
      "fills": [
        {
          "key": "person",
          "label": "Made for",
          "default": "my brother Dan, for his 40th"
        },
        {
          "key": "clues",
          "label": "Answers and clues",
          "default": "WAFFLES = what we ate at 2am in Lisbon; KAYAK = the boat that sank; DANTHEMAN = his nickname"
        },
        {
          "key": "title",
          "label": "Puzzle title",
          "default": "Dan’s Big 4-0 Crossword"
        }
      ],
      "prompt": "Build a printable crossword puzzle for {person}, titled \"{title}\".\n\nUse these answers and clues, in the form ANSWER = clue: {clues}. Write code that arranges them into a valid crossword grid where answers cross at shared letters, adding extra simple words and clues of your own if too few cross, and strip spaces and punctuation from answers. Number the squares in the usual way and list the Across and Down clues.\n\nShow it as a clean web page that opens from index.html: the grid is playable on screen with the keyboard, with check and reveal buttons, and it prints on one page. The print view has a second page with the answer key and a short card line from me at the bottom.\n\nUse a bold, playful look with high-contrast black and white squares, and keep it readable when printed in black and white.",
      "done_when": [
        "The grid is valid and every given answer appears in it",
        "Clues are numbered and match the grid",
        "The print view fits the puzzle on one page and the answer key on another"
      ],
      "needs": []
    },
    {
      "id": "bedtime-story-book",
      "category": "gifts",
      "title": "Bedtime story book",
      "description": "A short illustrated story starring your kid, as a printable PDF.",
      "minutes": 20,
      "fills": [
        {
          "key": "child",
          "label": "Child’s name",
          "default": "Theo, age 4"
        },
        {
          "key": "adventure",
          "label": "The adventure",
          "default": "finds a lost baby cloud and carries it home"
        },
        {
          "key": "friend",
          "label": "Sidekick",
          "default": "his stuffed rabbit, Mr. Button"
        }
      ],
      "prompt": "Write and illustrate a gentle bedtime story of 8 short pages starring {child}, who {adventure}, with {friend} along.\n\nTone: warm, calm and slightly funny, with simple words and a repeating little refrain that a sleepy child can join in on. The last page winds down to sleep. No scary parts and no villains. Write it fresh and original.\n\nMake one soft watercolor illustration per page in a consistent style, with the characters looking the same on every page. Lay out each page with the picture above and large, easy-to-read text below, plus a cover and a closing page.\n\nSave the finished book as a printable PDF in portrait pages, and keep the images and the text in the project folder too. No text is baked into the illustrations.",
      "done_when": [
        "The PDF has a cover, 8 story pages and a closing page",
        "The child and the sidekick look the same on every page",
        "The story has no scary scenes and ends with sleep"
      ],
      "needs": [
        "image_tool"
      ]
    },
    {
      "id": "our-story-timeline",
      "category": "gifts",
      "title": "Our story timeline",
      "description": "An anniversary timeline of your photos, places and dates.",
      "minutes": 30,
      "fills": [
        {
          "key": "couple",
          "label": "Who",
          "default": "Maria and Sam"
        },
        {
          "key": "moments",
          "label": "Key moments",
          "default": "met at a bookshop in 2016, first trip to Lisbon, moved in together, the wedding"
        },
        {
          "key": "look",
          "label": "Look",
          "default": "warm film photos with handwritten notes"
        }
      ],
      "prompt": "Build a scrolling timeline web page for {couple}, in the style of {look}.\n\nTurn these moments into timeline entries, in date order: {moments}. Each entry has a date, a title, a short caption, a place and a photo from a folder named photos; show a friendly placeholder where a photo is missing. Keep every entry in one plain data file that is easy to edit, and add a small drawn map of the places that does not need any map service.\n\nMake the page feel like turning pages: entries slide in as you scroll, a progress line shows how far through the story you are, and it ends on a big closing note. It must also print cleanly as a keepsake.\n\nIt opens straight from index.html with no build step. Support keyboard navigation and reduced motion.",
      "done_when": [
        "Entries appear in date order from the data file",
        "A missing photo shows a placeholder rather than a broken image",
        "Printing keeps the layout and the closing note"
      ],
      "needs": []
    },
    {
      "id": "flashcard-coach",
      "category": "learning",
      "title": "Flashcard coach",
      "description": "Turns any topic into spaced-repetition flashcards.",
      "minutes": 30,
      "fills": [
        {
          "key": "topic",
          "label": "Topic",
          "default": "Spanish phrases for travel"
        }
      ],
      "prompt": "Build a local flashcard app for {topic}.\n\nStart with 40 cards, let me add and edit cards, and schedule reviews with a simple spaced-repetition rule (again, hard, good, easy).\n\nShow my streak and the cards due today. Data stays in a local file.",
      "done_when": [
        "40 starter cards are there on first run",
        "Rating a card changes when it comes back",
        "The due-today count is right"
      ],
      "needs": []
    },
    {
      "id": "playable-explainer",
      "category": "learning",
      "title": "Playable explainer",
      "description": "Any concept as an interactive page you can poke at.",
      "minutes": 30,
      "fills": [
        {
          "key": "concept",
          "label": "Concept",
          "default": "how compound interest grows"
        },
        {
          "key": "audience",
          "label": "Audience",
          "default": "a curious 12-year-old"
        }
      ],
      "prompt": "Build an interactive single-page explainer of {concept} for {audience}.\n\nDo not write an article with a few pictures. Make the page something to play with: two or three live visualizations driven by sliders, buttons or dragging, so that changing a setting immediately changes what is drawn. Walk the reader through it in short steps, each ending with a small prediction question such as what happens if this goes up, and then let them check it.\n\nDraw everything with plain JavaScript and SVG or canvas, with no libraries that need an account or a download at run time. Use friendly plain language, a clear visual style, high-contrast text and labels on every control. Everything works with the keyboard and stops moving when the visitor prefers reduced motion.\n\nIt opens straight from index.html with no build step.",
      "done_when": [
        "index.html opens in a browser with no build step",
        "Moving a control changes the drawing right away",
        "Every step ends with a question the reader can check"
      ],
      "needs": []
    },
    {
      "id": "math-quest",
      "category": "learning",
      "title": "Math quest",
      "description": "A level-based math game made for your kid’s grade.",
      "minutes": 35,
      "fills": [
        {
          "key": "grade",
          "label": "Grade",
          "default": "grade 3"
        },
        {
          "key": "world",
          "label": "Adventure",
          "default": "a map of floating islands with friendly sky pirates"
        },
        {
          "key": "topic",
          "label": "Skills",
          "default": "multiplication and simple fractions"
        }
      ],
      "prompt": "Build an original browser math game for {grade}, set in {world}.\n\nThe player travels through 10 levels, each with a handful of short problems on {topic}, matched to the grade. Make the problems randomly generated so replays differ. A wrong answer gets a hint and a second try, never a punishment; a right answer earns a star, and three stars open the next level. Start easy and ramp up, and move a child down a step when they struggle. Add a calm parent page with the skills practiced and the problems missed most.\n\nDraw all the art in code. The game uses big buttons, works with the keyboard, a mouse and touch, and has an optional sound switch that starts off. It saves progress for each child in the browser, with no sign-in and nothing sent anywhere.\n\nIt opens straight from index.html with no build step.",
      "done_when": [
        "There are 10 levels and three stars open the next one",
        "Problems match the grade and differ between plays",
        "Progress is kept after a reload and a wrong answer gives a hint"
      ],
      "needs": []
    },
    {
      "id": "typing-trainer",
      "category": "learning",
      "title": "Typing trainer",
      "description": "Typing practice that uses your own words or code.",
      "minutes": 30,
      "fills": [
        {
          "key": "source",
          "label": "Practice text",
          "default": "my own emails and notes pasted in"
        },
        {
          "key": "goal",
          "label": "Goal",
          "default": "reach 60 words per minute at 97 percent accuracy"
        }
      ],
      "prompt": "Build a typing practice app that uses {source} as the lessons.\n\nI can paste or drop in text, including source code, and the app breaks it into short passages. While I type, the current character is highlighted, mistakes show right away without blocking me, and a live panel shows speed and accuracy. After each passage show a summary and a keyboard heatmap of the keys I miss most, and make the next passage drill those keys. Support code with symbols and indentation.\n\nTrack progress toward this goal: {goal}, with a simple chart of speed and accuracy over time. Keep everything in a local file in the browser or on disk, and make the text size, font and contrast adjustable.\n\nIt runs by opening index.html, or by one command in a README, with no accounts.",
      "done_when": [
        "Pasted text becomes passages that can be typed",
        "The summary shows speed, accuracy and the most-missed keys",
        "Progress is kept after a reload"
      ],
      "needs": []
    },
    {
      "id": "meal-planner",
      "category": "home",
      "title": "Meal planner",
      "description": "Plan the week and get one merged grocery list.",
      "minutes": 40,
      "fills": [
        {
          "key": "household",
          "label": "Who eats",
          "default": "two adults and one picky kid"
        },
        {
          "key": "diet",
          "label": "Food rules",
          "default": "no pork, lots of vegetarian dinners, quick on weeknights"
        },
        {
          "key": "budget",
          "label": "Weekly budget",
          "default": "$120"
        }
      ],
      "prompt": "Build a local weekly meal planner for {household}.\n\nA weekly grid has breakfast, lunch and dinner rows that I can fill by dragging recipes in. Start it with 20 original recipes that follow these rules: {diet}. Each recipe has ingredients with amounts, steps, time and a cost estimate that I can edit. Show the week’s estimated cost against a budget of {budget}, and warn me gently when I go over.\n\nOne button builds a single grocery list for the week that merges matching ingredients, scales for the number of people, groups items by aisle, lets me check items off and has a print view. Let me copy a week to the next one and mark items as already in the pantry.\n\nSave everything in a local SQLite file. It runs with one command and opens in the browser, and includes tests for the merge and the cost total.",
      "done_when": [
        "Planned recipes produce one merged grocery list",
        "The weekly cost total matches the recipes planned",
        "The plan is still there after the app restarts"
      ],
      "needs": []
    },
    {
      "id": "chore-wheel",
      "category": "home",
      "title": "Chore wheel",
      "description": "A fair chore rotation with a spin for the surprises.",
      "minutes": 25,
      "fills": [
        {
          "key": "people",
          "label": "Who is in",
          "default": "Mom, Dad, Zoe, Max"
        },
        {
          "key": "chores",
          "label": "Chores",
          "default": "dishes, trash, laundry, vacuuming, feeding the cat"
        },
        {
          "key": "look",
          "label": "Look",
          "default": "a bright carnival prize wheel"
        }
      ],
      "prompt": "Build a local chore rotation app for {people}, styled like {look}.\n\nChores: {chores}. Each week the app deals out the chores fairly, rotating so nobody gets the same one twice in a row, balancing by effort points I can edit, and never giving someone a chore they are marked as skipping. A big wheel on the main screen spins to pick the surprise chore of the day, with a satisfying slowing-down motion and a plain result card for people who prefer reduced motion.\n\nShow a tidy board of who has what this week with a checkbox for each chore, and a small history of who did how much so fairness is easy to see. Save everything in a local file.\n\nIt opens in the browser with one command from a README, and works on a phone-sized screen so it can sit on the fridge tablet.",
      "done_when": [
        "The weekly deal rotates chores and respects the skips",
        "The wheel spin picks a chore and shows the result",
        "Checked-off chores and history survive a restart"
      ],
      "needs": []
    },
    {
      "id": "plant-care-tracker",
      "category": "home",
      "title": "Plant care tracker",
      "description": "Watering reminders and a photo log for every plant.",
      "minutes": 35,
      "fills": [
        {
          "key": "plants",
          "label": "Your plants",
          "default": "a fiddle-leaf fig, two pothos, a snake plant, basil on the sill"
        },
        {
          "key": "look",
          "label": "Look",
          "default": "a leafy greenhouse journal"
        }
      ],
      "prompt": "Build a local plant care app styled like {look}.\n\nStart with these plants: {plants}. Each plant has a name, a room, a watering interval, a light need, notes and a photo log where I add dated photos from my Mac so I can watch it grow. Suggest a sensible watering interval and light for common plants, and let me change it.\n\nA Today screen shows what needs water, what is coming up, and what is overdue, with one tap to mark watered and optional fertilizing and repotting reminders. Reminders appear in the app and, if I allow it, as macOS notifications, with no email and no account. Keep photos and data in a local folder.\n\nIt runs with one command and opens in the browser. Include tests for the due-date logic.",
      "done_when": [
        "The Today screen lists what is due and what is overdue",
        "Marking a plant watered resets its next date",
        "Photos added to a plant are still there after a restart"
      ],
      "needs": []
    },
    {
      "id": "trip-planner-map",
      "category": "home",
      "title": "Trip planner map",
      "description": "Your itinerary drawn on a simple map from coordinates you enter.",
      "minutes": 40,
      "fills": [
        {
          "key": "trip",
          "label": "Trip",
          "default": "10 days in Portugal"
        },
        {
          "key": "stops",
          "label": "Stops",
          "default": "Lisbon 38.72,-9.14; Sintra 38.80,-9.38; Porto 41.15,-8.61"
        },
        {
          "key": "look",
          "label": "Look",
          "default": "an old paper travel map"
        }
      ],
      "prompt": "Build a local trip planner for {trip}, styled like {look}.\n\nI enter stops as a name with latitude and longitude, like these: {stops}. Draw them on a simple map made from the coordinates alone, with no map service and no downloaded tiles: a faint graticule of latitude and longitude lines, numbered pins and a route line in order, scaled to fit. If you want land shapes, draw a rough bundled outline you create yourself, otherwise leave it plain.\n\nNext to the map is the itinerary: a day-by-day list where I add stops, dates, notes, a place to sleep and a cost. Drag to reorder and the route redraws. Show distance between stops as the crow flies, total distance, days and estimated cost, and let me print the itinerary as a clean one-page handout.\n\nSave the trip in a local file and let me export and import it. It opens straight from index.html with no build step.",
      "done_when": [
        "Stops entered as coordinates appear in order on the map",
        "Reordering the itinerary redraws the route and the distances",
        "The trip is kept after a reload and prints on one page"
      ],
      "needs": []
    }
  ]
}
"""##
}
