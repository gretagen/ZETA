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
    "Returning void because nothing is left behind.",
  },
  forget = {
    "Looks like it's sweeping time!",
    "Gotta sweep sweep sweep!",
    "Like a memory, you forget.",
    "It's just a burning memory.",
    "Every legend, no matter how great, fades with time",
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
    "No worries it's very simple" 	
  },

  reprovide = {
    "If you can't update, considering clearing cache instead of reproviding.",
    "Network disconnected I suppose?",
    "Package failed to install I suppose",
    "Shared library not found I suppose?",
    "Remember to report any bugs on the github!"
  },

}

return quotes
