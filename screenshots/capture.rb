# frozen_string_literal: true

# Captures the nine README screenshots against the dummy host app, wearing an
# invented food-delivery brand (Pepperbox).
#
#   bundle exec ruby screenshots/capture.rb
#
# Deliberately NOT a Minitest file (no `_test.rb` suffix, and outside the
# Rakefile's `test/**/*_test.rb` pattern): `rake ci` must not drive a browser
# nine times, and the seeded rows below are committed rather than rolled back,
# which every transactional test in the suite would trip over. It runs against
# its own SQLite file for the same reason.
#
# Every shot is captured through Chrome DevTools with the SAME device metrics
# aspect (9:7) and a deviceScaleFactor chosen to land on it, so all nine PNGs
# come out at exactly 900x700 with no padding, letterboxing or resampling.

require "base64"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
OUT  = File.join(ROOT, "screenshots")

ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] ||= "sqlite3:#{File.join(ROOT, "tmp", "demo-screenshots.sqlite3")}"
FileUtils.mkdir_p(File.join(ROOT, "tmp"))

require File.expand_path("test/dummy/config/environment", ROOT)

ActiveRecord::Migrator.migrations_paths = [ File.expand_path("test/dummy/db/migrate", ROOT) ]
ActiveRecord::MigrationContext.new(ActiveRecord::Migrator.migrations_paths).migrate

require "capybara"
require "selenium-webdriver"

# --- The brand ---------------------------------------------------------------

DESK_NAME = "Pepperbox Support"

# The desk's face: the Pepperbox mark, as an inline SVG data URI, through the
# same `config.avatar` seam a host would hand an ActiveStorage attachment to.
DESK_AVATAR = "data:image/svg+xml;base64,#{Base64.strict_encode64(<<~SVG)}"
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#6D28D9"/><stop offset="1" stop-color="#A06BFF"/>
    </linearGradient></defs>
    <rect width="64" height="64" rx="18" fill="url(#g)"/>
    <path d="M22 45V19h12.5c6.2 0 10 3.4 10 8.9 0 5.6-3.9 9.1-10.3 9.1H29v8z"
          fill="#fff"/>
  </svg>
SVG

# Everything the demo needs about an order that the dummy's three-column
# `orders` table does not carry. Keyed by the column it does: the number.
ORDER_DETAILS = {
  "PB-4821" => { items: "Pad Thai + 2 sides",       restaurant: "Bangkok Bicycle", courier: "Ines M." },
  "PB-4796" => { items: "Margherita, extra basil",  restaurant: "Forno Vecchio",   courier: "Luc P." },
  "PB-4755" => { items: "Tonkotsu ramen, no egg",   restaurant: "Nine Bowls",      courier: "Dani R." },
  "PB-4702" => { items: "Salmon poke bowl",         restaurant: "Blue Harbour",    courier: "Sam T." },
  "PB-4688" => { items: "Chicken katsu curry",      restaurant: "Sumi Kitchen",    courier: "Ines M." },
  "PB-4830" => { items: "Barbacoa burrito + churros", restaurant: "Casa Lupita",   courier: "Nora V." },
  "PB-4834" => { items: "Paneer butter masala",     restaurant: "Tiffin Room",     courier: "Ines M." },
  "PB-4839" => { items: "Sushi platter for two",    restaurant: "Hanami",          courier: "Luc P." },
  "PB-4842" => { items: "Laksa + prawn crackers",    restaurant: "Kopi House",      courier: "Dani R." }
}.freeze

# The dummy's Order is the gem's fixture, and its `support_context` keys are
# Spanish because the gem's own presenter test asserts on them. The demo wants
# an English, food-shaped card, so it is reopened HERE rather than edited there.
class Order
  def details = ORDER_DETAILS.fetch(number, {})
  def support_label = [ details[:items], number ].compact.join(" · ")
  def support_status = state
  def support_url = "/admin/orders/#{id}"

  # chats' context line for an ordinary (non-support) conversation — the
  # courier thread in the inbox shot.
  def chat_subject_label = "#{details[:restaurant]} · #{number}"

  def support_context
    {
      "Order total" => format("EUR %.2f", total),
      "Restaurant" => details[:restaurant],
      "Courier" => details[:courier],
      "Placed" => created_at.strftime("%b %-d, %H:%M")
    }
  end
end

SupportDesk.reset!
Chats.reset!
Chats.configure { |config| config.messager_class = "User" }
Chats.register_messager(User)

SupportDesk.configure do |config|
  config.requester_class = "User"
  config.name = DESK_NAME
  config.avatar = DESK_AVATAR
  config.reply_within = 30.minutes
  config.at_risk_after = 10.minutes
  config.agents { User.where(admin: true) }

  config.topics do
    topic :order, about: Order, icon: "🍜", label: "An order",
                  ask: "Which order was it?",
                  placeholder: "Tell us what went wrong with this order"
    topic :payments, icon: "💳", label: "Payments and refunds" do
      topic :invoice, about: Invoice, label: "A receipt"
      topic :charge, label: "A charge I don't recognise"
    end
    topic :courier, icon: "🛵", label: "My courier"
    topic :account, icon: "👤", label: "My account"
    other label: "Something else", icon: "💬"
  end
end
SupportDesk.subscribe_to_chats!

# --- Seed --------------------------------------------------------------------

def reset_database!
  SupportDesk::Event.delete_all
  SupportDesk::Assignment.delete_all
  SupportDesk::Ticket.delete_all
  Chats::Message.delete_all
  Chats::Participant.delete_all
  Chats::Conversation.delete_all
  SupportDesk::Desk.delete_all
  Order.delete_all
  Invoice.delete_all
  User.delete_all
end

def order!(user:, number:, state: "delivered", total:)
  Order.create!(user: user, number: number, state: state, total: total)
end

# Timestamps are the difference between a screenshot and a demo: without them
# every row reads "13:07" and every waiting chip reads "0m". This walks a
# case's messages and events across the window it really happened in, and
# leaves `waiting_since` where the queue's chips want it.
def age!(ticket, opened_at:, waiting_since: nil)
  ticket.reload
  messages = ticket.conversation.messages.order(:id).to_a
  events = ticket.events.order(:id).to_a
  span = [ Time.current - opened_at - 60, 60 ].max
  steps = [ messages.size + events.size, 1 ].max

  messages.each_with_index do |message, index|
    at = opened_at + (span * index / steps)
    message.update_columns(created_at: at, updated_at: at)
  end
  # Events are readonly by design (append-only audit trail), so the demo
  # backdates them the only way the model allows: around it, in SQL.
  events.each_with_index do |event, index|
    SupportDesk::Event.where(id: event.id).update_all(created_at: opened_at + (span * index / steps))
  end

  last = messages.last&.created_at || opened_at
  ticket.conversation.update_columns(created_at: opened_at, updated_at: last, last_message_at: last)
  ticket.update_columns(created_at: opened_at, updated_at: last, opened_at: opened_at,
                        waiting_since: waiting_since || last)
  ticket
end

reset_database!

maya  = User.create!(name: "Maya Okonkwo", email: "maya@example.com", onboarded: true)
tomas = User.create!(name: "Tomás Rivera", email: "tomas@example.com", onboarded: true)
priya = User.create!(name: "Priya Raman", email: "priya@example.com", onboarded: true)
jonas = User.create!(name: "Jonas Weil", email: "jonas@example.com", onboarded: true)
dara  = User.create!(name: "Dara Nwosu", email: "dara@example.com", onboarded: true)
ines  = User.create!(name: "Ines Moreau", email: "ines@example.com", onboarded: true)
forno = User.create!(name: "Forno Vecchio", email: "kitchen@fornovecchio.example", onboarded: true)

nadia = User.create!(name: "Nadia Brenner", email: "nadia@pepperbox.example", admin: true)
omar  = User.create!(name: "Omar Haddad", email: "omar@pepperbox.example", admin: true)
User.create!(name: "Ruth Oyelaran", email: "ruth@pepperbox.example", admin: true)

# Creation order is picker order (`support_candidates_for` defaults to the
# requester's own association), so the one Maya already has a case open about
# sits third — marked, not hidden, which is the point of that row.
katsu    = order!(user: maya, number: "PB-4688", total: 19.60)
order!(user: maya, number: "PB-4796", total: 18.50)
pad_thai = order!(user: maya, number: "PB-4821", total: 24.80)
order!(user: maya, number: "PB-4702", total: 13.90)
ramen    = order!(user: maya, number: "PB-4755", state: "refunded", total: 15.20)

burrito = order!(user: tomas, number: "PB-4830", total: 21.40)
curry   = order!(user: priya, number: "PB-4834", total: 27.10)
sushi   = order!(user: jonas, number: "PB-4839", total: 46.00)
laksa   = order!(user: dara, number: "PB-4842", total: 16.75)

Invoice.create!(user: maya, number: "R-2291")

now = Time.current

# Nobody signed up this morning, and no order was placed after the case about
# it was opened. Both show on the agent's context card.
User.update_all(created_at: now - 14.months, updated_at: now - 14.months)
Order.find_each.with_index do |record, index|
  at = now - (index + 1).days - 5.hours
  record.update_columns(created_at: at, updated_at: at)
end

# Ordinary chats, so the grouped support row is standing next to conversations
# that AREN'T support — which is the whole point of that row.
def age_chat!(conversation, from:)
  conversation.messages.order(:id).each_with_index do |message, index|
    at = from + (index * 4).minutes
    message.update_columns(created_at: at, updated_at: at)
  end
  conversation.update_columns(last_message_at: conversation.messages.maximum(:created_at))
end

courier_chat = maya.chat_with(ines, about: pad_thai)
maya.message!(courier_chat, "I'm on the fourth floor, the buzzer is the top one.")
ines.message!(courier_chat, "I'm two streets away, the gate code didn't work.")
age_chat!(courier_chat, from: now - 52.minutes)

kitchen_chat = maya.chat_with(forno)
forno.message!(kitchen_chat, "We're out of buffalo mozzarella tonight — fior di latte instead?")
age_chat!(kitchen_chat, from: now - 4.hours)

# Maya's cases: the four the requester screens are about.
late = maya.ask_support!("The app says delivered but nothing arrived. I waited at the door the whole time.",
                         about: pad_thai)
age!(late, opened_at: now - 14.minutes)

cold = maya.ask_support!("Ramen arrived cold, with an egg in it.", about: ramen)
cold.assign!(to: nadia, by: nadia)
cold.reply!("So sorry! Refunded in full, back on your card in two working days.", by: nadia)
maya.message!(cold.conversation, "Thanks, that was quick.")
age!(cold, opened_at: now - 3.hours, waiting_since: now - 6.minutes)
# Maya has this thread open in the screenshot, so she has read it: no
# "new messages" divider between her and the answer she is looking at.
cold.conversation.participants.find_by(messager: maya)&.update_columns(last_read_at: Time.current)

charge = maya.ask_support!("There's a 4.90 charge from last Tuesday I don't recognise.", topic: "payments/charge")
charge.assign!(to: omar, by: omar)
charge.reply!("That's the small-order fee on PB-4702. Happy to take you through it.", by: omar)
age!(charge, opened_at: now - 26.hours)

settled = maya.ask_support!("Can I change the address on a scheduled order?", topic: :other)
settled.assign!(to: nadia, by: nadia)
settled.reply!("Yes — open the order and tap Edit address, up to 30 minutes before the delivery window.",
               by: nadia)
settled.close!(by: nadia)
age!(settled, opened_at: now - 6.days)

# Other people's cases, so the console queue looks like a Tuesday morning.
priya_case = priya.ask_support!("Half the order is missing — no naan, no raita.", about: curry)
priya_case.assign!(to: nadia, by: nadia)
age!(priya_case, opened_at: now - 3.hours, waiting_since: now - 2.hours - 10.minutes)

jonas_case = jonas.ask_support!("Charged twice for the same platter.", about: sushi)
jonas_case.assign!(to: omar, by: omar)
jonas_case.reply!("I can see both authorisations. I'm releasing the duplicate now.", by: omar)
age!(jonas_case, opened_at: now - 25.minutes)

unclaimed = jonas.ask_support!("Can I add a tip after the order is closed?", topic: :other)
age!(unclaimed, opened_at: now - 4.minutes)

knock = dara.ask_support!("Nobody knocked and the app closed the order as delivered.", about: laksa)
age!(knock, opened_at: now - 35.minutes)

# The case every console shot is taken on: a hand-off with a note, an internal
# note nobody outside the desk will ever read, and an answer signed by the
# human who wrote it.
flagship = tomas.ask_support!("The courier marked it delivered at the wrong building — number 8, not 18.",
                              about: burrito)
flagship.assign!(to: omar, by: omar)
flagship.note!("Third wrong-building drop for this courier this week. Flagged to courier ops.", by: omar)
flagship.reply!("I can see the drop pin was 80m off. Refunding in full, and tonight's order is on us.",
                by: omar)
flagship.hand_off!(to: nadia, note: "You own the Casa Lupita relationship — can you close the loop?", by: omar)
# A second note, from the agent who was handed the case: it lands in the
# timeline and nowhere else, which is the difference the note shot is about.
flagship.note!("Picked this up from Omar. Calling Casa Lupita this afternoon.", by: nadia)
age!(flagship, opened_at: now - 95.minutes, waiting_since: now - 70.minutes)

MAYA_ID = maya.id
NADIA_ID = nadia.id
COLD_CONVERSATION_ID = cold.conversation.id
FLAGSHIP_ID = flagship.id
KATSU_TOKEN = SupportDesk::Wizard.sign_subject(katsu)

puts "seeded: #{SupportDesk::Ticket.count} tickets, #{Chats::Message.count} messages"

# --- Browser -----------------------------------------------------------------

CANVAS = [ 900, 700 ].freeze   # every PNG, exactly
PHONE  = [ 540, 420 ].freeze   # requester screens: 9:7, captured at 1.667x
DESK   = [ 720, 560 ].freeze   # console screens:   9:7, captured at 1.25x

Capybara.app = Rails.application
Capybara.server = :puma, { Silent: true }
Capybara.default_max_wait_time = 8

Capybara.register_driver :demo do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--hide-scrollbars")
  options.add_argument("--force-color-profile=srgb")
  options.add_argument("--window-size=1200,900")
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

session = Capybara::Session.new(:demo, Rails.application)
cdp = session.driver.browser

def emulate!(cdp, width, height)
  cdp.execute_cdp("Emulation.setDeviceMetricsOverride",
                  width: width, height: height,
                  deviceScaleFactor: CANVAS[0].to_f / width, mobile: false)
end

def shoot!(cdp, name)
  data = cdp.execute_cdp("Page.captureScreenshot", format: "png", captureBeyondViewport: false)
  File.binwrite(File.join(OUT, "#{name}.png"), Base64.decode64(data.fetch("data")))
  puts "  -> #{name}.png"
end

def login(session, user_id)
  session.visit "/test_login/#{user_id}"
  session.assert_text "ok"
end

# Turbo's cable stream sources never connect here (the dummy's Action Cable
# adapter is :test) — nothing waits on them, but the element is a stray
# artefact in a screenshot, so it goes. The blur keeps a focus ring out too.
SETTLE = <<~JS
  document.querySelectorAll("turbo-cable-stream-source").forEach((el) => el.remove());
  if (document.activeElement) document.activeElement.blur();
JS

def settle(session)
  session.execute_script(SETTLE)
  sleep 0.4
end

# Scroll until the card +selector+ lives in starts exactly at the top edge of
# the frame, and say so if it couldn't. A cell that opens on a sliced bubble
# or a sliver of the card above it reads as a bad crop rather than a chosen
# frame, which is the one thing nine identical frames can't carry.
#
# The page is padded first because the last card on a page cannot be scrolled
# to the top without somewhere left to scroll to; the padding is page
# background, below the fold, and never appears in a shot.
def flush_to!(session, selector)
  top = session.evaluate_script(<<~JS)
    (function () {
      // A real element, not padding on <body>: the console's body is a flex
      // container with height 100%, and its bottom padding does not grow the
      // document's scrollable height there.
      const spacer = document.createElement("div");
      spacer.style.cssText = "height:900px;flex:0 0 900px";
      document.body.appendChild(spacer);

      const card = document.querySelector(#{selector.to_json}).closest("section, details");
      if (!card) return null;
      window.scrollTo(0, Math.round(card.getBoundingClientRect().top + window.scrollY));
      return Math.round(card.getBoundingClientRect().top);
    })();
  JS

  raise "nothing to frame for #{selector}" if top.nil?
  raise "#{selector} sits #{top}px from the top edge, not flush" unless top.zero?
end

FileUtils.mkdir_p(OUT)

# --- 1. The grouped inbox row ------------------------------------------------

emulate!(cdp, *PHONE)
login(session, MAYA_ID)
session.visit "/messages"
session.assert_selector ".chats-row--group"
settle(session)
shoot!(cdp, "01-inbox")

# --- 2. Topic picker ---------------------------------------------------------

session.visit "/messages/support/new"
session.assert_selector "h1", text: "What do you need help with?"
settle(session)
shoot!(cdp, "02-topics")

# --- 3. Order picker ---------------------------------------------------------

session.visit "/messages/support/new?topic=order"
session.assert_selector ".support-desk-choice__label", minimum: 2
settle(session)
shoot!(cdp, "03-subject")

# --- 4. Compose, with the context card ---------------------------------------

session.visit "/messages/support/new?about=#{KATSU_TOKEN}"
session.assert_selector "textarea[name=message]"
session.fill_in "message", with: "The curry arrived but the katsu was missing from the bag."
settle(session)
shoot!(cdp, "04-compose")

# --- 5. The thread, with a signed agent reply --------------------------------

session.visit "/messages/#{COLD_CONVERSATION_ID}"
session.assert_selector ".chats-message__signature"
# The thread opens at the top; the signature this shot is about is the last
# thing in it, so scroll the message pane the way a reader would.
session.execute_script(<<~JS)
  const pane = document.querySelector(".chats-thread__scroll");
  if (pane) pane.scrollTop = pane.scrollHeight;
JS
settle(session)
shoot!(cdp, "05-thread")

# --- 6. The agent queue ------------------------------------------------------

emulate!(cdp, *DESK)
login(session, NADIA_ID)
session.visit "/admin/support"
session.assert_selector "h1"
settle(session)
shoot!(cdp, "06-queue")

# --- 7. One case: context card + transcript ----------------------------------

session.visit "/admin/support/#{FLAGSHIP_ID}"
session.assert_selector "h1"
settle(session)
shoot!(cdp, "07-case")

# --- 8. The internal note composer -------------------------------------------
#
# Narrow, like the hand-off shot below: the console stacks below 640px, and a
# card that spans the frame is the only way either of these two lands FLUSH on
# the top edge. In the two-column layout the columns are different heights, so
# every scroll position slices whichever card the other column is in the
# middle of — which in a grid of identical frames reads as a careless crop.

emulate!(cdp, *PHONE)
session.visit "/admin/support/#{FLAGSHIP_ID}?compose=note"
session.assert_selector "textarea[name=body]"
flush_to!(session, "textarea[name=body]")
settle(session)
shoot!(cdp, "08-note")

# --- 9. Hand-off and assignment history --------------------------------------

session.visit "/admin/support/#{FLAGSHIP_ID}"
session.assert_selector "details summary"
session.execute_script('document.querySelectorAll("details").forEach((el) => (el.open = true));')
flush_to!(session, "aside details")
settle(session)
shoot!(cdp, "09-handoff")

session.quit

# The README grid is only a grid if every cell is the same shape. Nothing
# resizes these — the device metrics above land on the canvas exactly — so
# this is the check that the metrics are still right, not a repair step.
sizes = Dir[File.join(OUT, "*.png")].sort.to_h do |path|
  head = File.binread(path, 33)
  [ File.basename(path), head[16, 8].unpack("N2") ]
end
sizes.each { |name, (width, height)| puts format("  %-16s %dx%d", name, width, height) }
odd = sizes.reject { |_, size| size == CANVAS }
raise "not every screenshot is #{CANVAS.join("x")}: #{odd.keys.join(", ")}" if odd.any?

puts "done — #{sizes.size} screenshots at #{CANVAS.join("x")}"
