import Foundation

/// Prize winners, carried in the app because they change once a year and Wikidata's
/// public services refuse frequent requests. Years are the year each prize was given.
/// Checked against the prizes' own winner lists on 2026-11-24 (Booker 2026,
/// National Book Award 2026, Hugo 2026, Nebula 2026, Pulitzer 2026, International
/// Booker 2026, 茅盾文学奖 11th, 2023). `scripts/fetch_prize_winners.py` helps
/// cross-check a new year against Wikidata, whose data has gaps and wrong years.
enum PrizeWinners {
    static let checked = "2026-11-24"

    static func list(_ selection: BookListSelection, now: Date = Date()) -> BookList {
        let rows = table[selection.chart] ?? ""
        let books = rows.split(separator: "\n").enumerated().compactMap { index, line -> ListedBook? in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, let year = Int(parts[0]) else { return nil }
            return ListedBook(rank: index + 1, bookID: "\(selection.chart.rawValue)-\(year)-\(index)", title: parts[1], author: parts[2],
                              source: .prizes, figure: selection.chart == .maoDun ? "\(year)年获奖" : "Won \(year)", year: year)
        }
        return BookList(selection: selection, published: "Winners through \(books.first?.year.map(String.init) ?? "")", fetchedAt: now, books: books)
    }

    static let table: [BookListChart: String] = [
        .booker: """
        2026|The End of Everything|M. John Harrison
        2025|Flesh|David Szalay
        2024|Orbital|Samantha Harvey
        2023|Prophet Song|Paul Lynch
        2022|The Seven Moons of Maali Almeida|Shehan Karunatilaka
        2021|The Promise|Damon Galgut
        2020|Shuggie Bain|Douglas Stuart
        2019|The Testaments|Margaret Atwood
        2019|Girl, Woman, Other|Bernardine Evaristo
        2018|Milkman|Anna Burns
        2017|Lincoln in the Bardo|George Saunders
        2016|The Sellout|Paul Beatty
        2015|A Brief History of Seven Killings|Marlon James
        2014|The Narrow Road to the Deep North|Richard Flanagan
        2013|The Luminaries|Eleanor Catton
        2012|Bring Up the Bodies|Hilary Mantel
        2011|The Sense of an Ending|Julian Barnes
        2010|The Finkler Question|Howard Jacobson
        2009|Wolf Hall|Hilary Mantel
        2008|The White Tiger|Aravind Adiga
        2007|The Gathering|Anne Enright
        2006|The Inheritance of Loss|Kiran Desai
        2005|The Sea|John Banville
        2004|The Line of Beauty|Alan Hollinghurst
        2003|Vernon God Little|DBC Pierre
        2002|Life of Pi|Yann Martel
        2001|True History of the Kelly Gang|Peter Carey
        2000|The Blind Assassin|Margaret Atwood
        1999|Disgrace|J. M. Coetzee
        1998|Amsterdam|Ian McEwan
        1997|The God of Small Things|Arundhati Roy
        1996|Last Orders|Graham Swift
        1995|The Ghost Road|Pat Barker
        1994|How Late It Was, How Late|James Kelman
        1993|Paddy Clarke Ha Ha Ha|Roddy Doyle
        1992|The English Patient|Michael Ondaatje
        1992|Sacred Hunger|Barry Unsworth
        1991|The Famished Road|Ben Okri
        1990|Possession|A. S. Byatt
        1989|The Remains of the Day|Kazuo Ishiguro
        1988|Oscar and Lucinda|Peter Carey
        1987|Moon Tiger|Penelope Lively
        1986|The Old Devils|Kingsley Amis
        1985|The Bone People|Keri Hulme
        1984|Hotel du Lac|Anita Brookner
        1983|Life & Times of Michael K|J. M. Coetzee
        1982|Schindler's Ark|Thomas Keneally
        1981|Midnight's Children|Salman Rushdie
        1980|Rites of Passage|William Golding
        1979|Offshore|Penelope Fitzgerald
        1978|The Sea, the Sea|Iris Murdoch
        1977|Staying On|Paul Scott
        1976|Saville|David Storey
        1975|Heat and Dust|Ruth Prawer Jhabvala
        1974|The Conservationist|Nadine Gordimer
        1974|Holiday|Stanley Middleton
        1973|The Siege of Krishnapur|J. G. Farrell
        1972|G.|John Berger
        1971|In a Free State|V. S. Naipaul
        1970|The Elected Member|Bernice Rubens
        1969|Something to Answer For|P. H. Newby
        """,
        .internationalBooker: """
        2026|Taiwan Travelogue|Yáng Shuāng-zǐ
        2025|Heart Lamp|Banu Mushtaq
        2024|Kairos|Jenny Erpenbeck
        2023|Time Shelter|Georgi Gospodinov
        2022|Tomb of Sand|Geetanjali Shree
        2021|At Night All Blood Is Black|David Diop
        2020|The Discomfort of Evening|Marieke Lucas Rijneveld
        2019|Celestial Bodies|Jokha Alharthi
        2018|Flights|Olga Tokarczuk
        2017|A Horse Walks Into a Bar|David Grossman
        2016|The Vegetarian|Han Kang
        """,
        .pulitzer: """
        2026|Angel Down|Daniel Kraus
        2025|James|Percival Everett
        2024|Night Watch|Jayne Anne Phillips
        2023|Demon Copperhead|Barbara Kingsolver
        2023|Trust|Hernan Diaz
        2022|The Netanyahus|Joshua Cohen
        2021|The Night Watchman|Louise Erdrich
        2020|The Nickel Boys|Colson Whitehead
        2019|The Overstory|Richard Powers
        2018|Less|Andrew Sean Greer
        2017|The Underground Railroad|Colson Whitehead
        2016|The Sympathizer|Viet Thanh Nguyen
        2015|All the Light We Cannot See|Anthony Doerr
        2014|The Goldfinch|Donna Tartt
        2013|The Orphan Master's Son|Adam Johnson
        2011|A Visit from the Goon Squad|Jennifer Egan
        2010|Tinkers|Paul Harding
        2009|Olive Kitteridge|Elizabeth Strout
        2008|The Brief Wondrous Life of Oscar Wao|Junot Díaz
        2007|The Road|Cormac McCarthy
        2006|March|Geraldine Brooks
        2005|Gilead|Marilynne Robinson
        2004|The Known World|Edward P. Jones
        2003|Middlesex|Jeffrey Eugenides
        2002|Empire Falls|Richard Russo
        2001|The Amazing Adventures of Kavalier & Clay|Michael Chabon
        2000|Interpreter of Maladies|Jhumpa Lahiri
        1999|The Hours|Michael Cunningham
        1998|American Pastoral|Philip Roth
        1997|Martin Dressler|Steven Millhauser
        1996|Independence Day|Richard Ford
        1995|The Stone Diaries|Carol Shields
        1994|The Shipping News|E. Annie Proulx
        1993|A Good Scent from a Strange Mountain|Robert Olen Butler
        1992|A Thousand Acres|Jane Smiley
        1991|Rabbit at Rest|John Updike
        1990|The Mambo Kings Play Songs of Love|Oscar Hijuelos
        1989|Breathing Lessons|Anne Tyler
        1988|Beloved|Toni Morrison
        1987|A Summons to Memphis|Peter Taylor
        1986|Lonesome Dove|Larry McMurtry
        1985|Foreign Affairs|Alison Lurie
        1984|Ironweed|William Kennedy
        1983|The Color Purple|Alice Walker
        1982|Rabbit Is Rich|John Updike
        1981|A Confederacy of Dunces|John Kennedy Toole
        1980|The Executioner's Song|Norman Mailer
        1979|The Stories of John Cheever|John Cheever
        1978|Elbow Room|James Alan McPherson
        1976|Humboldt's Gift|Saul Bellow
        1975|The Killer Angels|Michael Shaara
        1973|The Optimist's Daughter|Eudora Welty
        1972|Angle of Repose|Wallace Stegner
        1970|The Collected Stories of Jean Stafford|Jean Stafford
        1969|House Made of Dawn|N. Scott Momaday
        1968|The Confessions of Nat Turner|William Styron
        1967|The Fixer|Bernard Malamud
        1966|The Collected Stories of Katherine Anne Porter|Katherine Anne Porter
        1965|The Keepers of the House|Shirley Ann Grau
        1963|The Reivers|William Faulkner
        1962|The Edge of Sadness|Edwin O'Connor
        1961|To Kill a Mockingbird|Harper Lee
        1960|Advise and Consent|Allen Drury
        1959|The Travels of Jaimie McPheeters|Robert Lewis Taylor
        1958|A Death in the Family|James Agee
        1956|Andersonville|MacKinlay Kantor
        1955|A Fable|William Faulkner
        1953|The Old Man and the Sea|Ernest Hemingway
        1952|The Caine Mutiny|Herman Wouk
        1951|The Town|Conrad Richter
        1950|The Way West|A. B. Guthrie Jr.
        1949|Guard of Honor|James Gould Cozzens
        1948|Tales of the South Pacific|James A. Michener
        """,
        .nationalBook: """
        2026|Paradiso 17|Hannah Lillith Assadi
        2025|The True True Story of Raja the Gullible (and His Mother)|Rabih Alameddine
        2024|James|Percival Everett
        2023|Blackouts|Justin Torres
        2022|The Rabbit Hutch|Tess Gunty
        2021|Hell of a Book|Jason Mott
        2020|Interior Chinatown|Charles Yu
        2019|Trust Exercise|Susan Choi
        2018|The Friend|Sigrid Nunez
        2017|Sing, Unburied, Sing|Jesmyn Ward
        2016|The Underground Railroad|Colson Whitehead
        2015|Fortune Smiles|Adam Johnson
        2014|Redeployment|Phil Klay
        2013|The Good Lord Bird|James McBride
        2012|The Round House|Louise Erdrich
        2011|Salvage the Bones|Jesmyn Ward
        2010|Lord of Misrule|Jaimy Gordon
        2009|Let the Great World Spin|Colum McCann
        2008|Shadow Country|Peter Matthiessen
        2007|Tree of Smoke|Denis Johnson
        2006|The Echo Maker|Richard Powers
        2005|Europe Central|William T. Vollmann
        2004|The News from Paraguay|Lily Tuck
        2003|The Great Fire|Shirley Hazzard
        2002|Three Junes|Julia Glass
        2001|The Corrections|Jonathan Franzen
        2000|In America|Susan Sontag
        1999|Waiting|Ha Jin
        1998|Charming Billy|Alice McDermott
        1997|Cold Mountain|Charles Frazier
        1996|Ship Fever|Andrea Barrett
        1995|Sabbath's Theater|Philip Roth
        1994|A Frolic of His Own|William Gaddis
        1993|The Shipping News|E. Annie Proulx
        1992|All the Pretty Horses|Cormac McCarthy
        1991|Mating|Norman Rush
        1990|Middle Passage|Charles Johnson
        """,
        .hugo: """
        2026|The Everlasting|Alix E. Harrow
        2025|The Tainted Cup|Robert Jackson Bennett
        2024|Some Desperate Glory|Emily Tesh
        2023|Nettle & Bone|T. Kingfisher
        2022|A Desolation Called Peace|Arkady Martine
        2021|Network Effect|Martha Wells
        2020|A Memory Called Empire|Arkady Martine
        2019|The Calculating Stars|Mary Robinette Kowal
        2018|The Stone Sky|N. K. Jemisin
        2017|The Obelisk Gate|N. K. Jemisin
        2016|The Fifth Season|N. K. Jemisin
        2015|The Three-Body Problem|Cixin Liu
        2014|Ancillary Justice|Ann Leckie
        2013|Redshirts|John Scalzi
        2012|Among Others|Jo Walton
        2011|Blackout/All Clear|Connie Willis
        2010|The City & the City|China Miéville
        2010|The Windup Girl|Paolo Bacigalupi
        2009|The Graveyard Book|Neil Gaiman
        2008|The Yiddish Policemen's Union|Michael Chabon
        2007|Rainbows End|Vernor Vinge
        2006|Spin|Robert Charles Wilson
        2005|Jonathan Strange & Mr Norrell|Susanna Clarke
        2004|Paladin of Souls|Lois McMaster Bujold
        2003|Hominids|Robert J. Sawyer
        2002|American Gods|Neil Gaiman
        2001|Harry Potter and the Goblet of Fire|J. K. Rowling
        2000|A Deepness in the Sky|Vernor Vinge
        1999|To Say Nothing of the Dog|Connie Willis
        1998|Forever Peace|Joe Haldeman
        1997|Blue Mars|Kim Stanley Robinson
        1996|The Diamond Age|Neal Stephenson
        1995|Mirror Dance|Lois McMaster Bujold
        1994|Green Mars|Kim Stanley Robinson
        1993|A Fire Upon the Deep|Vernor Vinge
        1993|Doomsday Book|Connie Willis
        1992|Barrayar|Lois McMaster Bujold
        1991|The Vor Game|Lois McMaster Bujold
        1990|Hyperion|Dan Simmons
        1989|Cyteen|C. J. Cherryh
        1988|The Uplift War|David Brin
        1987|Speaker for the Dead|Orson Scott Card
        1986|Ender's Game|Orson Scott Card
        1985|Neuromancer|William Gibson
        1984|Startide Rising|David Brin
        1983|Foundation's Edge|Isaac Asimov
        1982|Downbelow Station|C. J. Cherryh
        1981|The Snow Queen|Joan D. Vinge
        1980|The Fountains of Paradise|Arthur C. Clarke
        1979|Dreamsnake|Vonda N. McIntyre
        1978|Gateway|Frederik Pohl
        1977|Where Late the Sweet Birds Sang|Kate Wilhelm
        1976|The Forever War|Joe Haldeman
        1975|The Dispossessed|Ursula K. Le Guin
        1974|Rendezvous with Rama|Arthur C. Clarke
        1973|The Gods Themselves|Isaac Asimov
        1972|To Your Scattered Bodies Go|Philip José Farmer
        1971|Ringworld|Larry Niven
        1970|The Left Hand of Darkness|Ursula K. Le Guin
        1969|Stand on Zanzibar|John Brunner
        1968|Lord of Light|Roger Zelazny
        1967|The Moon Is a Harsh Mistress|Robert A. Heinlein
        1966|Dune|Frank Herbert
        1966|This Immortal|Roger Zelazny
        1965|The Wanderer|Fritz Leiber
        1964|Way Station|Clifford D. Simak
        1963|The Man in the High Castle|Philip K. Dick
        1962|Stranger in a Strange Land|Robert A. Heinlein
        """,
        .nebula: """
        2026|The Buffalo Hunter Hunter|Stephen Graham Jones
        2025|Someone You Can Build a Nest In|John Wiswell
        2024|The Saint of Bright Doors|Vajra Chandrasekera
        2023|Babel|R. F. Kuang
        2022|A Master of Djinn|P. Djèlí Clark
        2021|Network Effect|Martha Wells
        2020|A Song for a New Day|Sarah Pinsker
        2019|The Calculating Stars|Mary Robinette Kowal
        2018|The Stone Sky|N. K. Jemisin
        2017|All the Birds in the Sky|Charlie Jane Anders
        2016|Uprooted|Naomi Novik
        2015|Annihilation|Jeff VanderMeer
        2014|Ancillary Justice|Ann Leckie
        2013|2312|Kim Stanley Robinson
        2012|Among Others|Jo Walton
        2011|Blackout/All Clear|Connie Willis
        2010|The Windup Girl|Paolo Bacigalupi
        2009|Powers|Ursula K. Le Guin
        2008|The Yiddish Policemen's Union|Michael Chabon
        2007|Seeker|Jack McDevitt
        2006|Camouflage|Joe Haldeman
        2005|Paladin of Souls|Lois McMaster Bujold
        2004|The Speed of Dark|Elizabeth Moon
        2003|American Gods|Neil Gaiman
        2002|The Quantum Rose|Catherine Asaro
        2001|Darwin's Radio|Greg Bear
        2000|Parable of the Talents|Octavia E. Butler
        1999|Forever Peace|Joe Haldeman
        1998|The Moon and the Sun|Vonda N. McIntyre
        1997|Slow River|Nicola Griffith
        1996|The Terminal Experiment|Robert J. Sawyer
        1995|Moving Mars|Greg Bear
        1994|Red Mars|Kim Stanley Robinson
        1993|Doomsday Book|Connie Willis
        1992|Stations of the Tide|Michael Swanwick
        1991|Tehanu|Ursula K. Le Guin
        1990|The Healer's War|Elizabeth Ann Scarborough
        1989|Falling Free|Lois McMaster Bujold
        1988|The Falling Woman|Pat Murphy
        1987|Speaker for the Dead|Orson Scott Card
        1986|Ender's Game|Orson Scott Card
        1985|Neuromancer|William Gibson
        1984|Startide Rising|David Brin
        1983|No Enemy But Time|Michael Bishop
        1982|The Claw of the Conciliator|Gene Wolfe
        1981|Timescape|Gregory Benford
        1980|The Fountains of Paradise|Arthur C. Clarke
        1979|Dreamsnake|Vonda N. McIntyre
        1978|Gateway|Frederik Pohl
        1977|Man Plus|Frederik Pohl
        1976|The Forever War|Joe Haldeman
        1975|The Dispossessed|Ursula K. Le Guin
        1974|Rendezvous with Rama|Arthur C. Clarke
        1973|The Gods Themselves|Isaac Asimov
        1972|A Time of Changes|Robert Silverberg
        1971|Ringworld|Larry Niven
        1970|The Left Hand of Darkness|Ursula K. Le Guin
        1969|Rite of Passage|Alexei Panshin
        1968|The Einstein Intersection|Samuel R. Delany
        1967|Babel-17|Samuel R. Delany
        1967|Flowers for Algernon|Daniel Keyes
        1966|Dune|Frank Herbert
        """,
        .maoDun: """
        2023|雪山大地|杨志军
        2023|宝水|乔叶
        2023|本巴|刘亮程
        2023|千里江山图|孙甘露
        2023|回响|东西
        2019|人世间|梁晓声
        2019|牵风记|徐怀中
        2019|北上|徐则臣
        2019|主角|陈彦
        2019|应物兄|李洱
        2015|江南三部曲|格非
        2015|这边风景|王蒙
        2015|生命册|李佩甫
        2015|繁花|金宇澄
        2015|黄雀记|苏童
        2011|你在高原|张炜
        2011|天行者|刘醒龙
        2011|蛙|莫言
        2011|推拿|毕飞宇
        2011|一句顶一万句|刘震云
        2008|秦腔|贾平凹
        2008|额尔古纳河右岸|迟子建
        2008|暗算|麦家
        2008|湖光山色|周大新
        2005|张居正|熊召政
        2005|无字|张洁
        2005|历史的天空|徐贵祥
        2005|英雄时代|柳建伟
        2005|东藏记|宗璞
        2000|长恨歌|王安忆
        2000|尘埃落定|阿来
        2000|抉择|张平
        2000|茶人三部曲|王旭烽
        1997|战争和人|王火
        1997|白鹿原|陈忠实
        1997|白门柳|刘斯奋
        1997|骚动之秋|刘玉民
        1991|平凡的世界|路遥
        1991|少年天子|凌力
        1991|穆斯林的葬礼|霍达
        1991|都市风流|孙力、余小惠
        1991|第二个太阳|刘白羽
        1991|浴血罗霄|萧克
        1985|黄河东流去|李准
        1985|沉重的翅膀|张洁
        1985|钟鼓楼|刘心武
        1982|许茂和他的女儿们|周克芹
        1982|东方|魏巍
        1982|李自成（第二卷）|姚雪垠
        1982|将军吟|莫应丰
        1982|冬天里的春天|李国文
        1982|芙蓉镇|古华
        """
    ]
}
