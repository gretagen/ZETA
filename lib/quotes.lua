-- quotes.lua -- random quotes the zeta manager has
-- quotes change based on what action you are currently running.
-- you can disable quotes using the --no-quote flag or in the config

math.randomseed(os.time()) -- Needed for quotes to be randomized

local quotes = {
  transcend = {
    "Let's not go outdated.",
    "Gotta keep up with the future.",
    "Gotta live with the times.",
    "Let's not stay in the past.",
    "Let's see what's new.",
    "Elevate to heaven.",
    "Aim for transcendence.",
    "We will go beyond.",
    "Life is full of changes.",
    "Have you checked the news?",
    "In my restless dreams, I see package updates.",
    "Nothing ever doesn't change.",
    "Maybe someday we'll have more maintenance for those..",
    "ZETA package updates? what a funny joke.",
    "A rare occurence is when ZETA has package updates.",
    "A reminder to frequently create generations in case something breaks",
    "I get high on your memory",
    "Feels more outdated than Debian...",
    "Forget the past, leave it away, let's break things again or not?",
    "1 in a 100 chance that there's a package update.",
    "We've been wanting to contact you about your packages extended warranty",
    "Haliade OS is not responsible for any damage to property or person occuring during the transcending.",
    "They always say time changes things, but you actually have to change them yourself.",
  },

  remove = {
    "We sometimes don't need things anymore.",
    "Think before removing.",
    "With time, comes obsolescence.",
    "Sometimes we need to clean up.",
    "Let's not break anything this time...",
    "Sometimes letting go does more good than bad.",
    "Storage is not a privilege everyone has.",
    "We have to get rid of useless things.",
    "We (probably) don't need those anymore",
    "Let's see if the system breaks after the removal of the requested package",
    "Everything that lives is designed to end.",
    "Nothing built can last forever.",
    "You only lose what you cling to.",
    "Recycling bin: destination unknown.",
    "Crossing fingers that nothing else depends on this...",
    "If anything breaks, let's hope a generation will save you.",
    "To delete is to make room for the new.",
    "A reminder to frequently create generations in case something breaks.",
    "Dividing packages by 0",
    "[[Hyperlink Blocked]].",
    "It's time to drop, LET'S A GOOO!!!!",
    "Returning void because nothing is left behind.",
    "Error: nothing, stop reading this and focus on removing this package",
    "hippopotomonstrosesquipedaliophobia",
  },
  forget = {
    "Looks like it's sweeping time!",
    "Gotta sweep sweep sweep!",
    "Like a memory, you forget.",
    "It's just a burning memory.",
    "Every legend, no matter how great, fades with time",
    "Reminder: nevermind",
    "Can rememberr",
    "Don't use -Forget, they put something in it, to make you forget, I don't even remember how I got here...",
  },

  list = {
    "Let's see what we've got here.",
    "An inventory of your digital footprint.",
    "To list is to know; to know is to control.",
    "Opening the book of records...",
    "Let's count our blessings (and packages).",
    "Let's see what mess we've made.",
    "Taking stock of the digital universe.",
    "A catalog of things that exist, for now.",
    "A list is a peaceful antidote to anxiety.",
    "Order is the shape upon which beauty and justice depend.",
    "Because trying to remember everything is a rookie mistake.",
    "Listing things makes you feel productive even when you're not.",
    "Listing all the things you forgot you installed.",
    "Printing the roll call of your system's inhabitants.",
    "Because scrolling through things blindly is so last year.",
    "Unspooling the infinite scroll...",
    "There is beauty in a well-ordered array.",
    "To list is to bring light to the invisible.",
    "Grocery list, except it's already in the house.",
  },
  
  default = {
    "We all have to try new things.",
    "If it's not there just subspace-merge",
    "Starting up ZETA for you",
    "We'll get it all someday",
    "Any delivery service wouldn't ship that fast",
    "Fast and noisy, like a wind turbine.",
    "Loading Zenith Energy Turbine Archive",
    "Providing packages since 2026",
    "Lua's a good language for a package manager I promise",
    "Bloating your system again?",
    "Please pray the network gods for a stable connection",
    "Unpacking boxes you'll probably forget about in six months",
    "Let's hope this installs on the first try",
    "From the void of the repository, creation takes shape.",
    "Brace for impact for potential dependency hell",
    "Hope you have enough disk space for this.",
    "Because your machine clearly needs more stuff in it.",
    "Let's hope this won't conflict with anything.",
    "A reminder to frequently create generations in case something breaks.",
    "Trust me this will be fast! (i think)",
    "ZETA probably will end up having more quotes than lines of code",
  },

  localize = {
    "These aren't the packages you are looking for.",
    "If it's not there just subspace-merge.",
    "Not all those who wander are lost.",
    "To find yourself, think for yourself.",
    "May your search yield more than just error logs.",
    "The answer is out there... probably.",
    "Querying the cosmos (or at least the package repository)...",
    "Seeking, and hopefully finding.",
    "Scanning the horizon for matches.",
    "Let's see what turns up when we shine a light here.",
    "But you found me, congratulations, was it worth it?",
    "To seek is to admit you don't already know everything.",
    "Looking into the abyss, hoping it returns a package name.",
    "Let's see if what you're looking for actually exists.",
    "Curiosity didn't kill the cat; it just ran -Localize.",
    "Illuminating the dark corners of the repository...",
    "Because scrolling blindly is a thing of the past.",
   },

  help = {
    "No worries it's very simple",
    "Let's help someone like you:",
  },

  reprovide = {
    "If you can't update, consider clearing cache instead of reproviding.",
    "Network disconnected I suppose?",
    "Package failed to install I suppose",
    "Shared library not found I suppose?",
    "Remember to report any bugs on the github!",
  },

  slowdownload = {
   "I identify myself as a cockroach.",
   "This is a waste of your time",
   "Consider getting a better router",
   "For your own sanity please get better internet access",
   "Slow isn't it?",
   "It's not your fault if your internet is so mediocre",
   "Feels like we're still in the 90's",
   "Patience, my child",
   "This is not a ZETA issue, this is just your internet being slow.",
   "You're too slow",
  },

  isolate = {
  	"It was for the greater good ma'am!",
  	"Reproducible, Reliable, With init Freedom.",
  	"To save you from dependency hell.",
  	"Isolating is a way to know ourselves.",
  	"But your isolation must not be mechanical, but spiritual, that is, must be elevation.",
  	"There's only two ways to be completely alone in this world, lost in a crowd or in total isolation.",
    "Liberty is the possibility of isolation.",
    "Prevent conflicts, at a cost. (Your storage)",
    "Composing demands a degree of isolation.",
    "Doctor, are you sure this will work?",
  },
  solve = {
  	"The solver of the absolute fabric.",
  	"Seriously...",
  	"It's such an enigma.",
  	"And this is why you isolate packages, people.",
  	"NOOOOOOOOOOAEGHHHHHHHH",
  	"Just reinstall with --isolate at this point.",
  	"Another day, another breakage to solve.",
  	"You know if I wasn't here you'd be troubleshooting for hours right?",
  	"davinci resolve can't do this btw",
  	"we cannot solve problems with the same thinking we used to create.",
  	"Focus on the solution, not the problem",
  	"Solve the problem, or leave the problem, but don't live with the problem",
  	"awh come on man :<",
  	"The problem contains the solution.",
  	"Does he know",
    "RAAHAHSAHFDAKJLJWOIPRJFVKIOPFVWJFOVRJFADOPIJOPWUTGOJVDLFKLEWRJOPWJIKEOSIJHH",
    "Someday, this will all be BAD memory..",
    "I just knew it was going to be one of those days...",
  },
}

-- Runtime API

-- Global switch: zeta.lua calls set_enabled() from --no-quote and the quotes
-- config so runtime quotes (slow downloads) honor both.
local enabled = true

function quotes.set_enabled(v)
  enabled = (v == true)
end

function quotes.is_enabled()
  return enabled
end

-- Random element of `list`; nil when the list is empty or not a table.
function quotes.pick(list)
  if type(list) ~= "table" or #list == 0 then return nil end
  return list[math.random(#list)]
end

-- Selection rule for the startup banner. Only -Provide --isolate gets the
-- isolate quotes: -ReProvide/--LocalProvide with --isolate keep their own
-- command quotes, and -Remove --isolate keeps the remove quotes.
function quotes.for_command(cmd, isolate)
  if isolate and cmd == "provide" and quotes.isolate then
    return quotes.isolate
  end
  return quotes[cmd] or quotes.default
end

return quotes
