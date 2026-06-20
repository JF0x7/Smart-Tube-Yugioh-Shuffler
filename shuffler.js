// SmartTubeYu-Gi-Oh Image Shuffler

// Original deck list
const baseDeck = [
  { name: "Clockwork Brother - Gearheart Wizard", image: "cards/ClockWorkBroGW.png" },
  { name: "Clamshell Security", image: "cards/clamshellsecurity.jpg" },
  { name: "Blue-Eyes White Dragon", image: "cards/BlueEyes.png" },
  { name: "The ClockWork Brother Grim", image: "cards/ClockBros.jpg" },
  { name: "Rainbow Ranger 69", image: "cards/69Horseman.jpg" },
  { name: "Aurelion", image: "cards/Aurelion.png" },
  { name: "Clockwork Brohter - Wooden Wizard", image: "cards/cbWw.png" },
  { name: "Calamity Lock Pistol", image: "cards/CLP.jpg" },
  { name: "Conduit of Infinite Power", image: "cards/ConduitIP.jpg" },
  { name: "Concor", image: "cards/Concor.png" },
  { name: "Black Luster Cavalier", image: "cards/DarkKnight.jpg" },
  { name: "DDN Network Interconnect", image: "cards/DDN.jpg" },
];

const deck = [];
const hand = [];

// Render deck + hand
function render() {
  const deckDiv = document.getElementById("deck");
  const handDiv = document.getElementById("hand");

  deckDiv.innerHTML = "";
  handDiv.innerHTML = "";

  document.getElementById("deck-count").textContent = deck.length;
  document.getElementById("hand-count").textContent = hand.length;

  deck.forEach(card => {
    const div = document.createElement("div");
    div.className = "card";
    const img = document.createElement("img");
    img.src = card.image;
    img.alt = card.name;
    div.appendChild(img);
    deckDiv.appendChild(div);
  });

  hand.forEach(card => {
    const div = document.createElement("div");
    div.className = "card";
    const img = document.createElement("img");
    img.src = card.image;
    img.alt = card.name;
    div.appendChild(img);
    handDiv.appendChild(div);
  });
}

// Shuffle
function shuffleDeck() {
  for (let i = deck.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  render();
}

// Draw 1
function drawCard() {
  if (deck.length > 0) {
    hand.push(deck.shift());
    render();
  }
}

// Reset deck
function resetDeck() {
  hand.length = 0;
  deck.length = 0;
  baseDeck.forEach(card => deck.push({ ...card }));
  render();
}

// Load deck on start
resetDeck();

// (Restored to empty — no adaptive hand logic)
function updateHandLayout() {
  const hand = document.getElementById("hand");
  const cards = hand.querySelectorAll(".card");
  const count = cards.length;
}
