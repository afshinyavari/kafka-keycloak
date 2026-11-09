# OpenShift-plattformens – krav på framtida infrastruktur

## Bakgrund och syfte

Klustren installeras idag med UPI ovanpå VMware, och allt vi levererar till våra nyttjare står och faller med nät, lagring och kringtjänster som andra äger.

Det här dokumentet är vårt underlag till infraprojektet. Det beskriver vad plattformen behöver i den nya infrastrukturen. Vi har medvetet inte tagit med krav på den nuvarande miljön. Vi har försökt skriva krav på förmågor och mätbara egenskaper snarare än på specifika produkter, så att projektet har frihet att välja lösning. Där vi har en tydlig uppfattning om lösningen säger vi det och förklarar varför.

Kraven har id (t.ex. SITE-02) så att det går att hänvisa till dem i fortsatt dialog. Siffror markerade som preliminära vill vi stämma av tillsammans med er.

## Nuläge

Idag kör vi det man brukar kalla 2,5 siter: två fullvärdiga datahallar och en tredje plats som bara håller ett vittne för quorum. Detta medför tre problem som vi vill att den nya infrastrukturen löser.

1. Vittnessiten har ingen egen routing. Den kan inte ta trafik och den blir beroende av de andra två för att nås alls. I praktiken har vi därför inte tre oberoende felzoner.
2. Infrastrukturen är byggd för aktiv/passiv med en primär och en sekundär site. All trafik som lämnar klustret går via primärsiten, även när podden kör på sekundärsiten. Det ger onödig trafik mellan siterna och extra latens.
3. Eftersom vi är beroende av primärsiten är vi också beroende av att failovern till sekundärsiten fungerar när det väl gäller. Vad vi förstår är denna failover manuell och kräver handpåläggning i den sekundära siten.

Resultatet är att klustret är mer redundant på papperet än i verkligheten.

## Målbild

Vi vill köra OpenShift som stretchade kluster över tre fysiskt skilda siter, där alla tre är aktiva samtidigt. Varje site ska vara en egen felzon som klarar sig själv när någon av de andra försvinner.

Konkret betyder det:

- Klustret ska klara bortfall av en hel site utan manuella åtgärder och utan att någon failover i underliggande infrastruktur behöver lyckas.
- Trafik in till och ut från en applikation ska gå via den site där applikationen kör.
- Vi ska kunna erbjuda nyttjarna snabb lokal lagring och S3 som nås från alla siter. Data som ska överleva ett sitebortfall läggs i en meddelandekö, en databas eller S3.
- Styrning av trafik ska ske med DNS eller topologimedvetenhet i klustret, inte genom att nätet väljer en primär väg.
- Vi vill kunna välja mellan att fortsätta på VMware (VCF) och att köra bare metal. Inget av alternativen får göra att plattformen blir ett specialfall som resten av infrastrukturen inte är byggd för.

## Varför stretch över tre siter och inte ett kluster per site

Vi kör stateful-tjänster med höga tillgänglighetskrav i OpenShift, till exempel meddelandeköer och databaser. De har två egenskaper som styr hela designen. De replikerar själva mellan sina instanser, synkront, och väljer ny ledare automatiskt om en instans försvinner. Dessa driftas med kubernetes-operatorer, som sköter installation, uppgradering, certifikat, konfiguration och återställning, men som är bundna till ett kluster. Det är huvudskälet till att vi vill ha ett kluster som sträcker sig över tre siter.

### Det naturliga alternativet: ett kluster per site

Med ett kluster per site finns två sätt att få en tjänst att överleva ett sitebortfall. Det ena är en instans per site med replikering mellan klustren. Den replikeringen är asynkron och kräver att någon, en människa eller ett skript, bestämmer att en annan site ska ta över. Vid ett sitebortfall förloras det som inte hunnit replikeras, och tjänsten är nere tills failovern är gjord. Det är precis den sortens failover som målbilden säger att vi inte ska vara beroende av. Det andra är att sprida en och samma instans över de tre klustren. Då fungerar ledarval och synkron replikering som i stretch, men operatorn kan inte användas, och tjänsten måste installeras och driftas för hand.

I ett stretchat kluster ligger replikerna på olika siter men i samma kluster. Tjänsten väljer ny ledare själv, med synkron replikering förloras ingen bekräftad data, och operatorn fungerar som vanligt.

| Egenskap | Stretch över tre siter | Kluster per site, en instans per site med replikering mellan kluster | Kluster per site, en instans spridd över klustren utan operator |
| --- | --- | --- | --- |
| Ledarval vid sitebortfall | Automatiskt, inbyggt i tjänsten | Manuell eller skriptad failover mellan kluster | Automatiskt, inbyggt i tjänsten |
| Dataförlust vid sitebortfall (RPO) | Ingen för bekräftade skrivningar | Det som inte hunnit replikeras asynkront | Ingen för bekräftade skrivningar |
| Drift och livscykel | Operatorn sköter det | Operatorn i varje kluster, plus replikeringen som egen komponent | Manuellt. Operatorerna är bundna till ett kluster och kan inte användas när tjänsten är spridd över flera |
| Quorum | Tre röster i tre felzoner | Quorum per site, inget gemensamt | Tre röster i tre felzoner, men över klustergränser |
| Skydd mot logiska fel | Sämre, ett kluster påverkar alla siter | Bättre, felet stannar i en site | Bättre. Ett plattformsfel stannar i en site och tjänsten fortsätter på de två andra. Fel i tjänsten själv slår mot alla siter, men det gäller stretch också |
| Krav på nätet mellan siterna | Låg latens, klustertrafik genom brandvägg | Lägre latenskrav, men bara för att replikeringen är asynkron | Samma latenskrav som stretch, och trafiken mellan instanserna måste routas mellan klustren |
| För nyttjarna | En plattform, spridning sker automatiskt | Varje team hanterar flera kluster | Varje team hanterar flera kluster |

För stateful-tjänsterna står valet mellan sämre tillgänglighet med replikering mellan kluster, eller att ge upp operatorerna och drifta tjänsterna för hand. Stretch är det enda alternativet som ger både automatisk hantering av sitebortfall och drift via operatorer. Tjänster utan state skulle klara sig med ett kluster per site, men när vi ändå bygger stretch för de som är stateful, blir det naturligt att köra även stateless där. Det ger en plattform och en klustertyp att förvalta i stället för flera.

### Varför tre siter och inte två

Allt som bygger på quorum, alltså etcd och de stateful-tjänster som replikerar synkront, behöver en majoritet för att fortsätta fungera. Med två siter kan ingen av dem avgöra om den andra är borta eller bara onåbar. Med tre fullvärdiga siter klarar vi bortfall av vilken site som helst. Det är också därför ett vittne utan egen routing inte räcker.

### Var data som ska överleva ett sitebortfall ska ligga

Vi erbjuder ingen blocklagring som överlever ett sitebortfall, och vi kräver det inte heller av infrastrukturen. En applikation som behöver behålla data när en site försvinner lägger i stället sin data i en tjänst som redan replikerar mellan siterna:

- en meddelandekö, som Kafka eller AMQP
- en databas, som Postgres
- S3 som ligger utanför klustret.

Meddelandeköerna och databaserna körs i klustret och ska ha snabb lokal lagring. De replikerar själva mellan siterna, så replikerad lagring under dem skulle bara ge dubbel replikering och längre svarstider. Övriga volymer är lokala för en site, och den som använder dem får räkna med att data inte överlever ett sitebortfall. Vi har övervägt att köra mjukvarudefinierad lagring i klustret, men bedömer att den drift det kräver inte står i proportion till nyttan.

### Riskerna med stretch och hur vi hanterar dem

Stretch skyddar mot fysiska fel men inte mot logiska. En misslyckad uppgradering eller en felkonfiguration påverkar alla tre siter samtidigt. Det hanteras genom:

1. Test- och staging-miljöer som också är stretchad över tre siter, där uppgraderingar och ändringar körs först.
2. Backup av data till S3 utanför klustret.
3. Två stretchade produktionskluster i stället för ett. Ett sitebortfall hanteras automatiskt inom varje kluster. Om ett helt kluster går sönder på grund av ett logiskt fel kan kritiska tjänster ta över i det andra, till exempel Kafka med MirrorMaker 2 eller Postgres med ett replica cluster. Den vägen är asynkron och kräver manuell failover, men behövs bara i det ovanliga fallet. Klustren uppgraderas och ändras aldrig samtidigt, och stateless-tjänster kan köra aktivt i båda bakom DNS.
4. All konfiguration i Git, så att ett kluster går att bygga upp från grunden.

Två kluster skyddar mot fel i ett kluster, men inte mot fel i det som båda delar såsom nät, brandväggar, DNS, IdP och S3. Det är en av anledningarna till att kraven på gemensamma tjänster (GEM-01 och GEM-02) är viktiga.

Kravet på latens mellan siterna kommer inte från Kubernetes utan från tillgänglighetskraven på stateful tjänsterna. Kafka och Postgres som replikerar synkront över tre siter väntar på en rundtur per skrivning oavsett om de kör i OpenShift eller på virtuella maskiner. Det som är specifikt för ett stretchat kluster är trafiken mellan noderna, och det är därför kraven på brandväggar längre ner i dokumentet är så specifika.

## Krav

### Siter och nät mellan siter

| Id | Krav | Varför |
| --- | --- | --- |
| SITE-01 | Tre fysiskt skilda siter, alla fullvärdiga med egen routing, egen WAN- och internetanslutning, egen ström och kyla. | Ett vittne utan routing ger inte en tredje felzon. |
| SITE-02 | Latens mellan varje par av siter under 5 ms RTT (preliminärt). | etcd och synkron lagring tål inte hög latens. Varje commit i Postgres med synkron replika och varje skrivning i Kafka med acks=all väntar dessutom på en rundtur till en annan site, så latensen påverkar applikationernas prestanda direkt. Ligger siterna för långt ifrån varandra går stretch inte att genomföra. |
| SITE-03 | Bandbredd mellan siterna som räcker för replikering av lagring plus trafik mellan applikationer, med marginal för återuppbyggnad efter ett bortfall. Nivå tas fram tillsammans. | Återuppbyggnad efter ett sitebortfall ger toppar som är mycket högre än normal last. |
| SITE-04 | Varje site ska kunna nå de andra två via minst två oberoende vägar. | Vi vill inte att en enskild fiber eller ett enskilt vägval avgör quorum. |
| SITE-05 | Beskrivet beteende vid partition, då en site lever men tappar kontakten med de andra. | Vi behöver veta hur nätet beter sig för att kunna designa klustret rätt. |

### Brandvägg och L3 mellan siterna

Vi har inget behov av L2 mellan siterna. OpenShift fungerar bra med ett eget subnät per site och L3 däremellan. Däremot påverkas klustret av hur brandväggarna mellan siterna är byggda, eftersom trafiken mellan noderna i ett kluster skiljer sig från vanlig applikationstrafik.

Trafik mellan poddar på olika noder går inkapslad i Geneve-tunnlar (UDP 6081). En brandvägg mellan siterna ser därför bara trafik från nod till nod och kan inte se vilka poddar, namespaces eller applikationer som pratar med varandra inne i tunneln. Inspektion där ger alltså ingen extra säkerhet, bara latens och en till komponent som kan störa klustret. Segmentering mellan applikationer görs i stället i klustret med NetworkPolicy, där vi faktiskt ser vem som pratar med vem.

| Id | Krav | Varför |
| --- | --- | --- |
| FW-01 | Nodnäten i ett och samma kluster behandlas som en säkerhetszon. Trafik mellan dem släpps igenom utan inspektion enligt Red Hats portlista, utan korta sessionstimeouts och med kapacitet för all trafik mellan siterna. | Brandväggen ser bara Geneve-trafik nod till nod och kan inte inspektera innehållet. etcd och långlivade API-anslutningar är känsliga för latens, jitter och avbrutna sessioner. |
| FW-02 | Vägen mellan siterna, inklusive brandväggar, ska klara den MTU som klustret behöver. Geneve lägger till 100 byte per paket. Exakt värde bestäms tillsammans. | Fel MTU ger svårfelsökta problem där små paket går fram men stora inte gör det. |
| FW-03 | Uppgradering och failover av brandväggar mellan siterna får inte bryta etablerade sessioner mellan noder, eller ska planeras tillsammans med oss. | Tappat state kan ge omval av ledare i etcd och störningar i hela klustret. |
| FW-04 | IP-planen ska ha utrymme för routade pod-nät per namespace eller tenant, som annonseras med BGP från alla siter och kan användas i brandväggsregler. | Med L3 per site fungerar egress-IP dåligt. Ett namespace behöver en adress per site och trafiken kan gå ut via fel site. Routade pod-nät ger lokal utgång och en stabil adress per namespace att skriva regler mot. |
| FW-05 | Replikering mellan de två klustren, till exempel MirrorMaker 2 för Kafka och replikering för Postgres, ska kunna gå mellan siterna med brandväggsregler och bandbredd för det. | Det är vanlig applikationstrafik mellan kluster och omfattas inte av FW-01. |

### Trafik in och ut ur klustret

| Id | Krav | Varför |
| --- | --- | --- |
| TRAF-01 | Trafik ut från klustret ska kunna lämna via den site där podden kör. | Undviker att all trafik går via "primärsiten". |
| TRAF-02 | Inkommande trafik ska kunna tas emot på alla tre siter samtidigt. | Aktiv/aktiv/aktiv och inget beroende av failover. |
| TRAF-03 | Brandväggar och routing ska klara att en session går in på en site och svaret ut på en annan, eller så ska designen garantera symmetriska flöden per site. | Stateful brandväggar per site utan state-synk är en vanlig anledning till att aktiv/aktiv/aktiv inte fungerar. |
| TRAF-04 | Vi ska kunna peera BGP mot nätet i alla tre siter och annonsera adresser för services, ingress och egress. | Ger oss ett standardgränssnitt som fungerar likadant på VCF och bare metal. |
| TRAF-05 | Brandväggsregler och IP-planer ska acceptera källadresser från alla tre siter för samma applikation. | Applikationer flyttar mellan siter och tar sina egress-adresser med sig. |
| TRAF-06 | Vi behöver API-åtkomst till DNS för de zoner vi använder, så att poster kan skapas automatiskt från klustret. | Styrning via DNS får inte bero på manuella ärenden. |
| TRAF-07 | Om DNS-baserad lastbalansering (GSLB) används ska den ha hälsokontroller per site och korta TTL:er. | Annars pekar DNS på en site som inte svarar. |
| TRAF-08 | Proxy för utgående trafik och lastbalanserare för inkommande trafik ska finnas i varje site. | De ligger i datavägen. En proxy eller lastbalanserare i en annan site gör att trafiken ändå går via den siten, oavsett TRAF-01 och TRAF-02. |

### Gemensamma tjänster

Klustret överlever bara om två av tre siter finns kvar. En tjänst som finns aktiv i två siter nås därför alltid från minst en av de siter som är kvar. Vi kräver inte att varje stödtjänst finns i alla tre siter, men vi kräver att den fortsätter svara utan att något behöver flyttas.

| Id | Krav | Varför |
| --- | --- | --- |
| GEM-01 | DNS, NTP, AD/IdP och PKI ska finnas aktiva i minst två av tre siter, med redundans så att planerat underhåll inte lämnar en enda instans kvar. Tjänster som själva bygger på quorum ska finnas i alla tre. | Ett kluster över tre siter hjälper inte om en tjänst klustret behöver bara finns på en av dem. En ensam instans under underhåll är ett fel från stopp. En tjänst med quorum har samma problem med två siter som etcd har. |
| GEM-02 | Klienterna ska nå en instans som redan är aktiv, genom flera konfigurerade adresser eller anycast. Ingen gemensam tjänst får bero på att en VIP, ett kluster eller en manuell rutin flyttar tjänsten till en annan site vid ett sitebortfall. | Målbilden är att ingen failover i infrastrukturen ska behöva lyckas. Aktiv/passiv med automatisk failover är fortfarande en failover som måste lyckas. |

### Lagring

Vi vill erbjuda tre nivåer: snabb lokal lagring, S3 och enklare delad fillagring (NFS) från den NAS som finns idag. De två första är de viktigaste. Vi kör ingen egen mjukvarudefinierad lagring i klustret, så S3 och fillagring behöver levereras av infrastrukturen.

| Id | Krav | Varför |
| --- | --- | --- |
| LAG-01 | Snabb lokal lagring per nod eller per site (NVMe eller motsvarande) med låg latens. Ingen replikering krävs, applikationen ansvarar själv för sin redundans. | Våra viktigaste stateful-tjänster, som Kafka och Postgres, replikerar själva mellan siterna. Replikerad lagring under dem ger dubbel replikering och längre svarstider utan att höja tillgängligheten. Det här är vår viktigaste lagringsnivå. |
| LAG-02 | Utgår. Vi ställer inget krav på blocklagring som överlever ett sitebortfall. | Data som ska överleva ett sitebortfall läggs i en meddelandekö, en databas eller S3. Se avsnittet om var data som ska överleva ett sitebortfall ska ligga. |
| LAG-03 | S3-kompatibel objektlagring som nås från alla tre siter och klarar bortfall av en site. Vi behöver veta om replikeringen är synkron eller asynkron. Backup från de två klustren ska kunna ligga i separata buckets med separata behörigheter. | Den vanligaste lagringsformen för nya applikationer, och krävs för loggar, backup och registry. |
| LAG-04 | Block- och fillagring ska levereras via en CSI-drivrutin som är certifierad för OpenShift och stöder topologi (zoner) och volymexpansion. | Topologistöd krävs för att poddar ska hamna där deras data finns. Volymer måste kunna växa utan att data flyttas. |
| LAG-05 | Varje nivå ska ha angiven prestanda (IOPS, latens), RPO/RTO och en kapacitetsplan. | Vi måste kunna berätta för nyttjarna vad de får. |
| LAG-06 | Delad fillagring (NFS eller motsvarande) för volymer som flera poddar behöver montera samtidigt, levererad per site från den NAS som redan finns. Lägre prestanda än LAG-01 är godtagbart. Fillagringen behöver inte överleva ett sitebortfall, men varje volym ska vara knuten till en site via topologi (LAG-04) så att poddarna körs i samma site som sin volym. | Vissa applikationer behöver ett gemensamt filsystem, till exempel för uppladdade filer eller äldre applikationer som inte kan använda S3. Med site-bunden lagring går det att använda det som redan finns, och utan montering över länken mellan siterna. Den här nivån är inte avsedd för databaser eller Kafka. |

### Plattform: VCF eller bare metal

| Id | Krav | Varför |
| --- | --- | --- |
| PLAT-01 | Både VCF och bare metal ska vara möjliga val för OpenShift, och infrastrukturen ska designas så att båda ansluts på samma sätt (L3, BGP, samma IPAM och DNS). | Vi vill inte bli ett specialfall oavsett vilket vi väljer. |
| PLAT-02 | På VCF ska varje site motsvaras av ett eget vSphere-kluster som kan användas som en felzon i OpenShift. | OpenShift mappar zoner mot vSphere-kluster och datacenter. |
| PLAT-03 | På bare metal ska det finnas fysiska nätanslutningar, out-of-band-hantering (BMC) och provisioneringsnät per site. | Krävs för att installera och hantera servrar utan virtualiseringslager. |
| PLAT-04 | Vi ska ha tillgång till de API:er vi behöver för automatiserad installation och skalning (vCenter eller BMC). | Vi installerar och uppgraderar kluster automatiserat. |
| PLAT-05 | Plattformen ska bestå av minst två stretchade produktionskluster. Infrastrukturen ska dimensioneras för det: nodnät, adresser för API och ingress, BGP-peers och pod-nät för båda klustren i varje site, och kapacitet för två uppsättningar control plane- och infra-noder per site. | Två kluster skyddar mot logiska fel som slår ut ett helt kluster, till exempel en misslyckad uppgradering. Se riskerna med stretch. |

### Nätverksplattform: overlay och underlay

Oavsett vilken nätverksplattform som väljs, i det fysiska nätet eller som overlay i virtualiseringsplattformen, vill vi att klustret och nätet integreras i gränssnitten: routing via BGP och säkerhetsgrupper via API. Vi vill inte ersätta OpenShifts eget nätverk (OVN-Kubernetes) med en integration från nät- eller virtualiseringsplattformen. Det skulle göra oss beroende av en tredjepartsintegration med osäker framtid och support, och det skulle inte fungera likadant på VCF och bare metal.

| Id | Krav | Varför |
| --- | --- | --- |
| NÄT-01 | Klustrets eget nätverk (OVN-Kubernetes) ersätts inte av en integration från nät- eller virtualiseringsplattformen. | Tredjepartsintegrationer har osäker framtid och support, och samma modell ska fungera på VCF och bare metal. |
| NÄT-02 | BGP-peering i alla tre siter, oavsett om motparten är en overlay-router eller den fysiska fabricen, dimensionerad för två kluster (se TRAF-04). Vilka noder som peerar, och om route reflectors används, bestäms tillsammans. | Många fabricer har gränser för antal grannar per switch, och vi annonserar pod-nät enligt FW-04. |
| NÄT-03 | Nätets felzoner ska vara dokumenterade, inklusive hur stor del av nätet ett fel eller en uppgradering i kontrollplanet påverkar. Ett gemensamt kontrollplan över alla tre siter ska riskbedömas. | Ett gemensamt kontrollplan är en gemensam felzon. Det är samma skäl som till att vi kör två kluster. |
| NÄT-04 | Designen ska visa hur FW-01 genomförs i vald plattform. Nodnäten i ett kluster får inte delas upp i segment eller grupper som kräver regler eller brandvägg sinsemellan. | FW-01 går lätt förlorat i översättningen till plattformens konfigurationsmodell. |
| NÄT-05 | Säkerhetsgrupper i de lager som skriver brandväggsregler, både overlay och fabric, ska kunna fyllas via API med våra pod-nät och metadata (namespace, applikation). | Då kan mikrosegmentering bygga på vår metadata oavsett var regeln skrivs. |
| NÄT-06 | Gemensam IPAM och namngivningskonvention för nät och grupper. | Undviker att vi och infra pratar om samma sak med olika namn. |
| NÄT-07 | Bare metal ska kunna anslutas direkt till fabricen med L3 och BGP, utan overlay-lager från virtualiseringsplattformen. | Undviker två overlay-lager och gör bare metal till ett fullvärdigt alternativ (PLAT-01). |

### Samarbete och drift

| Id | Krav | Varför |
| --- | --- | --- |
| SAM-01 | Plattformsteamet deltar i designarbetet för nät, lagring och virtualisering. | Vi är beroende av besluten och kan bidra med krav tidigt. |
| SAM-02 | Bortfall av en site testas regelbundet och gemensamt, minst en gång per år. | Det är enda sättet att veta att designen håller. |
| SAM-03 | Ändringar i infrastrukturen som påverkar plattformen kommuniceras i förväg, med möjlighet för oss att testa. | Undviker överraskningar i produktion. |
