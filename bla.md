# OpenShift-plattformen – krav på framtida infrastruktur

Nov 5, 2026 · @Afshin

## Bakgrund och syfte

Vi är plattformsteamet som driftar OpenShift on-prem. Klustren installeras idag med UPI ovanpå VMware, och allt vi levererar till våra nyttjare står och faller med nät, lagring och kringtjänster som andra äger.

Det här dokumentet är vårt underlag till infraprojektet. Det beskriver vad plattformen behöver i den nya infrastrukturen. Vi har medvetet inte tagit med krav på den nuvarande miljön. Vi har försökt skriva krav på förmågor och mätbara egenskaper snarare än på specifika produkter, så att projektet har frihet att välja lösning. Där vi har en tydlig uppfattning om lösningen säger vi det och förklarar varför.

Kraven har id (t.ex. SITE-02) så att det går att hänvisa till dem i fortsatt dialog. Siffror markerade som preliminära vill vi stämma av tillsammans med er.

## Nuläge

Idag kör vi det man brukar kalla 2,5 siter: två fullvärdiga datahallar och en tredje plats som bara håller ett vittne för quorum. Det fungerar, men har tre problem som vi vill att den nya infrastrukturen löser.

1. Vittnessiten har ingen egen routing. Den kan inte ta trafik och den blir beroende av de andra två för att nås alls. I praktiken har vi därför inte tre oberoende felzoner.
2. Infrastrukturen är byggd för aktiv/passiv med en primär och en sekundär site. All trafik som lämnar klustret går via primärsiten, även när podden kör på sekundärsiten. Det ger onödig trafik mellan siterna och extra latens.
3. Eftersom vi är beroende av primärsiten är vi också beroende av att failovern till sekundärsiten fungerar när det väl gäller. Den är sällan testad på ett sätt som vi kan verifiera.

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

Vi kör stateful-tjänster med höga tillgänglighetskrav i OpenShift, främst Kafka och Postgres. De hanteras av operatorer som sköter replikering och automatisk failover, men bara inom ett och samma kluster. Det är huvudskälet till att vi vill ha ett kluster som sträcker sig över tre siter.

### Det naturliga alternativet: ett kluster per site

Med ett kluster per site måste replikeringen mellan siterna ske mellan kluster. För Kafka betyder det i praktiken MirrorMaker 2 och för Postgres replica- eller standby-kluster. Båda är asynkrona och kräver att någon, en människa eller ett skript, bestämmer att den andra siten ska ta över. Vid ett sitebortfall förlorar vi då data som inte hunnit replikeras, och tjänsten är nere tills failovern är gjord.

I ett stretchat kluster ligger replikerna på olika siter men i samma kluster. Operatorerna väljer ny ledare automatiskt, och med synkron replikering förloras ingen bekräftad data.

| Egenskap | Stretch över tre siter | Ett kluster per site |
| --- | --- | --- |
| Failover för Kafka och Postgres vid sitebortfall | Automatisk, sköts av operatorn | Manuell eller skriptad promotion mellan kluster |
| Dataförlust vid sitebortfall (RPO) | Ingen för bekräftade skrivningar | Det som inte hunnit replikeras asynkront |
| Quorum (etcd, Kafka KRaft, Postgres) | Tre röster i tre felzoner | Quorum per site, inget gemensamt |
| Skydd mot logiska fel (felaktig uppgradering, felkonfiguration) | Sämre, ett kluster påverkar alla siter | Bättre, felet stannar i en site |
| Krav på nätet mellan siterna | Låg latens för synkron replikering, och klustertrafik genom brandvägg | Lägre latenskrav, men bara för att replikeringen är asynkron. Bara applikationstrafik genom brandvägg |
| För nyttjarna | En plattform, spridning mellan siter sker automatiskt | Varje team måste själva hantera flera kluster |

Vi menar att ett kluster per site är ett rimligt val för tjänster som inte har state, men att det ger sämre tillgänglighet för de tjänster där kraven är högst.

### Varför tre siter och inte två

Allt som bygger på quorum, alltså etcd, Kafka KRaft och Postgres med synkron replikering, behöver en majoritet för att fortsätta fungera. Med två siter kan ingen av dem avgöra om den andra är borta eller bara onåbar. Med tre fullvärdiga siter klarar vi bortfall av vilken site som helst. Det är också därför ett vittne utan egen routing inte räcker.

### Var data som ska överleva ett sitebortfall ska ligga

Vi erbjuder ingen blocklagring som överlever ett sitebortfall, och vi kräver det inte heller av infrastrukturen. En applikation som behöver behålla data när en site försvinner lägger i stället sin data i en tjänst som redan replikerar mellan siterna:

- en meddelandekö, som Kafka eller AMQP
- en databas, som Postgres
- S3 som ligger utanför klustret.

Meddelandeköerna och databaserna körs i klustret och ska ha snabb lokal lagring. De replikerar själva mellan siterna, så replikerad lagring under dem skulle bara ge dubbel replikering och längre svarstider. Övriga volymer är lokala för en site, och den som använder dem får räkna med att data inte överlever ett sitebortfall. Vi har övervägt att köra mjukvarudefinierad lagring i klustret, men bedömer att den drift det kräver inte står i proportion till nyttan.

### Riskerna med stretch och hur vi hanterar dem

Stretch skyddar mot fysiska fel men inte mot logiska. En misslyckad uppgradering eller en felkonfiguration påverkar alla tre siter samtidigt. Det hanterar vi så här:

1. En testmiljö som också är stretchad över tre siter, där uppgraderingar och ändringar körs först.
2. Backup av data till S3 utanför klustret.
3. Två stretchade produktionskluster i stället för ett. Ett sitebortfall hanteras automatiskt inom varje kluster. Om ett helt kluster går sönder på grund av ett logiskt fel kan kritiska tjänster ta över i det andra, till exempel Kafka med MirrorMaker 2 eller Postgres med ett replica cluster. Den vägen är asynkron och kräver manuell failover, men behövs bara i det ovanliga fallet. Klustren uppgraderas och ändras aldrig samtidigt, och stateless-tjänster kan köra aktivt i båda bakom DNS.
4. All konfiguration i Git, så att ett kluster går att bygga upp från grunden.

Två kluster skyddar mot fel i ett kluster, men inte mot fel i det som båda delar: nät, brandväggar, DNS, IdP och S3. Det är en av anledningarna till att kraven på gemensamma tjänster (GEM-01 och GEM-02) är viktiga.

Kravet på latens mellan siterna kommer inte från Kubernetes utan från tillgänglighetskravet på de stateful tjänsterna. Kafka och Postgres som replikerar synkront över tre siter väntar på en rundtur per skrivning oavsett om de kör i OpenShift eller på virtuella maskiner. Det som är specifikt för ett stretchat kluster är trafiken mellan noderna, och det är därför kraven på brandväggar längre ner i dokumentet är så specifika.

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
| FW-04 | IP-planen ska ha utrymme för routade pod-nät per namespace eller tenant, som annonseras med BGP från alla siter och kan användas i brandväggsregler. | Med L3 per site fungerar egress-IP dåligt: ett namespace behöver en adress per site och trafiken kan gå ut via fel site. Routade pod-nät ger lokal utgång och en stabil adress per namespace att skriva regler mot. |
| FW-05 | Replikering mellan de två klustren, till exempel MirrorMaker 2 för Kafka och replikering för Postgres, ska kunna gå mellan siterna med brandväggsregler och bandbredd för det. | Det är vanlig applikationstrafik mellan kluster och omfattas inte av FW-01. |

### Trafik in och ut ur klustret

| Id | Krav | Varför |
| --- | --- | --- |
| TRAF-01 | Trafik ut från klustret ska kunna lämna via den site där podden kör. | Undviker att all trafik går via primärsiten. |
| TRAF-02 | Inkommande trafik ska kunna tas emot på alla tre siter samtidigt. | Aktiv/aktiv/aktiv och inget beroende av failover. |
| TRAF-03 | Brandväggar och routing ska klara att en session går in på en site och svaret ut på en annan, eller så ska designen garantera symmetriska flöden per site. | Stateful brandväggar per site utan state-synk är det vanligaste skalet till att aktiv/aktiv inte fungerar. |
| TRAF-04 | Vi ska kunna peera BGP mot nätet i alla tre siter och annonsera adresser för tjänster, ingress och egress. | Ger oss ett standardgränssnitt som fungerar likadant på VCF och bare metal. |
| TRAF-05 | Brandväggsregler och IP-planer ska acceptera källadresser från alla tre siter för samma tjänst. | Applikationer flyttar mellan siter och tar sina egress-adresser med sig. |
| TRAF-06 | Vi ska ha API-åtkomst till DNS för de zoner vi använder, så att poster kan skapas automatiskt från klustret. | Styrning via DNS får inte bero på manuella ärenden. |
| TRAF-07 | Om DNS-baserad lastbalansering (GSLB) används ska den ha hälsokontroller per site och korta TTL:er. | Annars pekar DNS på en site som inte svarar. |
| TRAF-08 | Proxy för utgående trafik och lastbalanserare för inkommande trafik ska finnas i varje site. | De ligger i datavägen. En proxy eller lastbalanserare i en annan site gör att trafiken ändå går via den siten, oavsett TRAF-01 och TRAF-02. |

### Gemensamma tjänster

Klustret överlever bara om två av tre siter finns kvar. En tjänst som finns aktiv i två siter nås därför alltid från minst en av de siter som är kvar. Vi kräver inte att varje stödtjänst finns i alla tre siter, men vi kräver att den fortsätter svara utan att något behöver flyttas. Proxy och lastbalanserare ligger i datavägen och hanteras under trafik (TRAF-08). Backupmål och registry ligger i S3 och hanteras under lagring (LAG-03).

| Id | Krav | Varför |
| --- | --- | --- |
| GEM-01 | DNS, NTP, AD/IdP och PKI ska finnas aktiva i minst två av tre siter, med redundans så att planerat underhåll inte lämnar en enda instans kvar. Tjänster som själva bygger på quorum ska finnas i alla tre. | Ett kluster över tre siter hjälper inte om en tjänst klustret behöver bara finns på en av dem. En ensam instans under underhåll är ett fel från stopp. En tjänst med quorum har samma problem med två siter som etcd har. |
| GEM-02 | Klienterna ska nå en instans som redan är aktiv, genom flera konfigurerade adresser eller anycast. Ingen gemensam tjänst får bero på att en VIP, ett kluster eller en manuell rutin flyttar tjänsten till en annan site vid ett sitebortfall. | Målbilden är att ingen failover i infrastrukturen ska behöva lyckas. Aktiv/passiv med automatisk failover är fortfarande en failover som måste lyckas. |

### Lagring

Vi vill erbjuda två nivåer: snabb lokal lagring och S3. Vi kör ingen egen mjukvarudefinierad lagring i klustret, så S3 behöver levereras av infrastrukturen.

| Id | Krav | Varför |
| --- | --- | --- |
| LAG-01 | Snabb lokal lagring per nod eller per site (NVMe eller motsvarande) med låg latens. Ingen replikering krävs, applikationen ansvarar själv för sin redundans. | Våra viktigaste stateful-tjänster, som Kafka och Postgres, replikerar själva mellan siterna. Replikerad lagring under dem ger dubbel replikering och längre svarstider utan att höja tillgängligheten. Det här är vår viktigaste lagringsnivå. |
| LAG-02 | Utgår. Vi ställer inget krav på blocklagring som överlever ett sitebortfall. | Data som ska överleva ett sitebortfall läggs i en meddelandekö, en databas eller S3. Se avsnittet om var data som ska överleva ett sitebortfall ska ligga. |
| LAG-03 | S3-kompatibel objektlagring som nås från alla tre siter och klarar bortfall av en site. Vi behöver veta om replikeringen är synkron eller asynkron. Backup från de två klustren ska kunna ligga i separata buckets med separata behörigheter. | Den vanligaste lagringsformen för nya applikationer, och krävs för loggar, backup och registry. |
| LAG-04 | Block- och fillagring ska levereras via en CSI-drivrutin som är certifierad för OpenShift och stöder topologi (zoner), snapshots och volymexpansion. | Topologistöd krävs för att poddar ska hamna där deras data finns. |
| LAG-05 | Varje nivå ska ha angiven prestanda (IOPS, latens), RPO/RTO och en kapacitetsplan. | Vi måste kunna berätta för nyttjarna vad de får. |

### Plattform: VCF eller bare metal

| Id | Krav | Varför |
| --- | --- | --- |
| PLAT-01 | Både VCF och bare metal ska vara möjliga val för OpenShift, och infrastrukturen ska designas så att båda ansluts på samma sätt (L3, BGP, samma IPAM och DNS). | Vi vill inte bli ett specialfall oavsett vilket vi väljer. |
| PLAT-02 | På VCF ska varje site motsvaras av ett eget vSphere-kluster som kan användas som en felzon i OpenShift. | OpenShift mappar zoner mot vSphere-kluster och datacenter. |
| PLAT-03 | På bare metal ska det finnas fysiska nätanslutningar, out-of-band-hantering (BMC) och provisioneringsnät per site. | Krävs för att installera och hantera servrar utan virtualiseringslager. |
| PLAT-04 | Vi ska ha tillgång till de API:er vi behöver för automatiserad installation och skalning (vCenter eller BMC). | Vi installerar och uppgraderar kluster automatiserat. |
| PLAT-05 | Plattformen ska bestå av minst två stretchade produktionskluster. Infrastrukturen ska dimensioneras för det: nodnät, VIP:er, BGP-peers och pod-nät för båda klustren i varje site, och kapacitet för två uppsättningar control plane- och infra-noder per site. | Två kluster skyddar mot logiska fel som slår ut ett helt kluster, till exempel en misslyckad uppgradering. Se riskerna med stretch. |

### Integration med NSX

Vi vill integrera med NSX, men vi vill inte ersätta OpenShifts eget nätverk (OVN-Kubernetes) med NSX. Det skulle göra oss beroende av en tredjepartsintegration med osäker framtid och support, och det fungerar inte om vi kör bare metal. Integrationen bör i stället ske i gränssnitten.

| Id | Krav | Varför |
| --- | --- | --- |
| NSX-01 | BGP-peering mellan klustret och NSX eller den fysiska fabricen i alla siter (se TRAF-04). | Routing på lika villkor som övriga miljöer. |
| NSX-02 | Vi ska via API kunna synka adresser och taggar (namespace, applikation, egress-IP) till grupper i NSX eller ACI (ESG). | Då kan brandväggsregler och mikrosegmentering i NSX eller ACI bygga på vår metadata. |
| NSX-03 | Gemensam IPAM och namngivningskonvention för nät och taggar. | Undviker att vi och infra pratar om samma sak med olika namn. |

### Om Cisco ACI används som underlay

Vi har förstått att ACI är aktuellt som underlay. Vi har inget emot det, men några av ACI:s egenskaper påverkar våra krav direkt. Kraven nedan gäller om ACI väljs.

| Id | Krav | Varför |
| --- | --- | --- |
| ACI-01 | Det ska vara dokumenterat vilka felzoner fabricen har och hur stor del av nätet ett fel eller en uppgradering av APIC kan påverka. Om Multi-Pod väljs ska riskerna med ett gemensamt kontrollplan för alla tre siter beskrivas. | Ett gemensamt kontrollplan är en gemensam felzon. Det är samma skäl som till att vi kör två kluster. |
| ACI-02 | ACI används som underlay. OpenShift fortsätter att använda OVN-Kubernetes som nätverksplugin, inte ACI CNI. | Vi vill inte göra klustrets nätverk beroende av en tredjepartsintegration, och samma modell ska fungera på VCF och bare metal. |
| ACI-03 | BGP-peering mot ACI i alla tre siter, till exempel med floating L3Out, dimensionerad för två kluster. Vilka noder som peerar, och om route reflectors används, bestäms tillsammans. | Antalet BGP-peers per border leaf är begränsat, och vi annonserar pod-nät enligt FW-04. |
| ACI-04 | FW-01 genomförs i ACI genom att nodnäten i ett kluster ligger i samma EPG eller ESG, eller har ett contract som tillåter all trafik mellan noderna. Trafiken mellan noderna leds inte genom en brandvägg via service graph. | Samma skäl som för FW-01. |
| ACI-05 | Bare metal-noder ska kunna anslutas direkt till ACI med L3 och BGP, utan NSX. | Undviker två overlay-lager och gör bare metal till ett fullvärdigt alternativ (PLAT-01). |

### Samarbete och drift

| Id | Krav | Varför |
| --- | --- | --- |
| SAM-01 | Plattformsteamet deltar i designarbetet för nät, lagring och virtualisering. | Vi är beroende av besluten och kan bidra med krav tidigt. |
| SAM-02 | Bortfall av en site testas regelbundet och gemensamt, minst en gång per år. | Det är enda sättet att veta att designen håller. |
| SAM-03 | Ändringar i infrastrukturen som påverkar plattformen kommuniceras i förväg, med möjlighet för oss att testa. | Undviker överraskningar i produktion. |

## Ansvarsfördelning

Flera av förmågorna i det här dokumentet kan levereras på olika nivåer: av infrastrukturen, av plattformen eller av varje applikation. Vi delar principen att tillgänglighet ska lösas så nära applikationen som är rimligt, och för Kafka och Postgres gör vi redan det. Men en förmåga som flyttas uppåt försvinner inte. Den måste lösas av någon, och ju högre upp desto fler gånger.

Tabellen visar vilka alternativ som finns och vad som händer om ingen tar ansvaret. Vi vill att varje rad får ett beslut i projektet.

| Förmåga | Infrastrukturen levererar | Plattformen levererar | Applikationen löser | Om ingen tar ansvaret |
| --- | --- | --- | --- | --- |
| Data som ska överleva ett sitebortfall | S3 med replikering mellan siterna (LAG-03) | Meddelandeköer och databaser som tjänster, med snabb lokal lagring | Lägger sin data i någon av dessa i stället för på lokala volymer | Data på lokala volymer försvinner vid ett sitebortfall |
| Snabb lokal lagring (LAG-01) | Lokala diskar eller lokal datastore per site | Exponerar lagringen i klustret med topologistöd | – | Kafka och Postgres får sämre prestanda eller dubbel replikering |
| Replikering för Kafka och Postgres | – | Operatorer, konfiguration och drift | Applikationsteamen använder plattformens tjänster | – |
| S3 som nås från alla siter (LAG-03) | Objektlagring med replikering mellan siter | Egen S3 i klustret. Kräver budget, hårdvara och kompetens som vi inte har idag | – | Loggar, backup och registry saknar en gemensam plats som tål sitebortfall |
| Trafik in och ut per site (TRAF-01 till TRAF-04, TRAF-08) | BGP-peering, routing, brandväggar, proxy och lastbalanserare per site | Annonserar adresser för tjänster och pod-nät | – | Trafiken går via en primär site, som idag |
| Gemensamma tjänster som överlever ett sitebortfall (GEM-01, GEM-02) | DNS, NTP, IdP och PKI aktiva i minst två siter, utan failover som måste lyckas | – | – | Ett bortfall av en site slår ut klustret även om klustret i sig klarar det |
| Test av sitebortfall (SAM-02) | Deltar och testar sin del | Deltar och testar sin del | – | Vi vet inte om designen fungerar förrän det är skarpt läge |

Vi har valt att inte erbjuda blocklagring som överlever ett sitebortfall. Data som måste finnas kvar läggs i en meddelandekö, en databas eller S3. Därför är S3 med replikering mellan siterna den viktigaste lagringstjänsten vi behöver från infrastrukturen, tillsammans med snabb lokal lagring. Om infrastrukturen inte levererar S3 måste plattformen göra det, och då behöver det finnas budget och resurser för det.

## Prioritering

Om allt inte kan levereras samtidigt är det här ordningen vi prioriterar i:

1. Tre fullvärdiga siter med latens och bandbredd enligt SITE-01 till SITE-05, dimensionerade för två stretchade kluster (PLAT-05).
2. Brandväggar mellan siterna som behandlar klustrets nodnät som en säkerhetszon och klarar MTU och failover utan att störa klustret, samt har regler och bandbredd för replikering mellan klustren (FW-01 till FW-03, FW-05).
3. Aktiv/aktiv/aktiv för trafik in och ut och för gemensamma tjänster (TRAF-01 till TRAF-03, TRAF-05, TRAF-08, GEM-01, GEM-02).
4. Snabb lokal lagring och S3 med replikering mellan siterna (LAG-01, LAG-03 till LAG-05).
5. BGP, routade pod-nät och API-integration mot DNS, NSX och ACI (TRAF-04, TRAF-06, TRAF-07, FW-04, NSX-01 till NSX-03, ACI-01 till ACI-05).
6. Stöd för både VCF och bare metal (PLAT-01 till PLAT-04). Helst ska infrastrukturen stödja båda, så att valet kan göras senare.

Kraven på samarbete (SAM-01 till SAM-03) gäller från projektets start.

## Öppna frågor till infraprojektet

- [ ] Vilka siter är aktuella, och vilken latens och bandbredd blir det mellan dem?
- [ ] Hur är brandväggarna tänkta att byggas, per site eller gemensamt, och klarar de asymmetriska flöden?
- [ ] Vilken lagringslösning planeras för lokal lagring och S3, och vem äger respektive nivå?
- [ ] Kommer bare metal att stödjas i nätdesignen fullt ut, eller bara VCF?
- [ ] Finns det API:er i NSX som vi får använda för att synka grupper och taggar?
- [ ] Om ACI väljs som underlay: blir det Multi-Pod eller Multi-Site, och hur stor del av nätet kan ett fel eller en uppgradering av APIC påverka?
- [ ] Hur ser tidplanen ut, och när behöver projektet våra preliminära siffror bekräftade?
- [ ] Vem levererar snabb lokal lagring per site, och i vilken form (lokala diskar eller lokal datastore)?
- [ ] Vem levererar S3 med replikering mellan siterna? Om det blir plattformen, vilken budget och vilka resurser följer med?
- [ ] Vilka av de gemensamma tjänsterna (DNS, NTP, IdP, PKI, proxy, backupmål) kommer att finnas i alla tre siter, och vilka inte?
- [ ] Vem samordnar test av sitebortfall, och hur ofta ska det göras?

