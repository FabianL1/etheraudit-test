contract Pray4Prey is mortal, usingOraclize, transferable {
	using strings
	for * ;

	struct Animal {
		uint8 animalType;
		uint128 value;
		address owner;
	}

	/** array holding ids of the curret animals*/
	uint32[] public ids;
	/** the id to be given to the net animal **/
	uint32 public nextId;
	/** the id of the oldest animal */
	uint32 public oldest;
	/** the animal belonging to a given id */
	mapping(uint32 => Animal) animals;
	/** the cost of each animal type */
	uint128[] public costs;
	/** the value of each animal type (cost - fee), so it's not necessary to compute it each time*/
	uint128[] public values;
	/** the fee to be paid each time an animal is bought in percent*/
	uint8 fee;
	/** the address of the old contract version. animals may be transfered from this address */
	address lastP4P;

	/** total number of animals in the game (uint32 because of multiplication issues) */
	uint32 public numAnimals;
	/** The maximum of animals allowed in the game */
	uint16 public maxAnimals;
	/** number of animals per type */
	mapping(uint8 => uint16) public numAnimalsXType;


	/** the query string getting the random numbers from oraclize**/
	string randomQuery;
	/** the type of the oraclize query**/
	string queryType;
	/** the timestamp of the next attack **/
	uint public nextAttackTimestamp;
	/** gas provided for oraclize callback (attack)**/
	uint32 public oraclizeGas;
	/** the id of the next oraclize callback*/
	bytes32 nextAttackId;


	/** is fired when new animals are purchased (who bought how many animals of which type?) */
	event newPurchase(address player, uint8 animalType, uint8 amount, uint32 startId);
	/** is fired when a player leaves the game */
	event newExit(address player, uint256 totalBalance, uint32[] removedAnimals);
	/** is fired when an attack occures */
	event newAttack(uint32[] killedAnimals);
	/** is fired when a single animal is sold **/
	event newSell(uint32 animalId, address player, uint256 value);


	/** initializes the contract parameters	 (would be constructor if it wasn't for the gas limit)*/
	function init(address oldContract) {
		if(msg.sender != owner) throw;
		costs = [100000000000000000, 200000000000000000, 500000000000000000, 1000000000000000000, 5000000000000000000];
		fee = 5;
		for (uint8 i = 0; i < costs.length; i++) {
			values.push(costs[i] - costs[i] / 100 * fee);
		}
		maxAnimals = 300;
		randomQuery = "10 random numbers between 1 and 1000";
		queryType = "WolframAlpha";
		oraclizeGas = 700000;
		lastP4P = oldContract; //allow transfer from old contract
		nextId = 500;
		oldest = 500;
	}

	/** The fallback function runs whenever someone sends ether
	   Depending of the value of the transaction the sender is either granted a prey or 
	   the transaction is discarded and no ether accepted
	   In the first case fees have to be paid*/
	function() payable {
		for (uint8 i = 0; i < costs.length; i++)
			if (msg.value == costs[i])
				addAnimals(i);

		if (msg.value == 1000000000000000)
			exit();
		else
			throw;

	}

	/** buy animals of a given type 
	 *  as many animals as possible are bought with msg.value
	 */
	function addAnimals(uint8 animalType) payable {
		giveAnimals(animalType, msg.sender);
	}

	/** buy animals of a given type forsomeone else
	 *  as many animals as possible are bought with msg.value
	 */
	function giveAnimals(uint8 animalType, address receiver) payable {
		uint8 amount = uint8(msg.value / costs[animalType]);
		if (animalType >= costs.length || msg.value < costs[animalType] || numAnimals + amount >= maxAnimals) throw;
		//if type exists, enough ether was transferred and there are less than maxAnimals animals in the game
		for (uint8 j = 0; j < amount; j++) {
			addAnimal(animalType, receiver, nextId);
			nextId++;
		}
		numAnimalsXType[animalType] += amount;
		newPurchase(receiver, animalType, amount, nextId - amount);
	}

	/**
	 *  adds a single animal of the given type
	 */
	function addAnimal(uint8 animalType, address receiver, uint32 nId) internal {
		if (numAnimals < ids.length)
			ids[numAnimals] = nId;
		else
			ids.push(nId);
		animals[nId] = Animal(animalType, values[animalType], receiver);
		numAnimals++;
	}



	/** leave the game
	 * pays out the sender's winBalance and removes him and his animals from the game
	 * */
	function exit() {
		uint32[] memory removed = new uint32[](50);
		uint8 count;
		uint32 lastId;
		uint playerBalance;
		for (uint16 i = 0; i < numAnimals; i++) {
			if (animals[ids[i]].owner == msg.sender) {
				//first delete all animals at the end of the array
				while (numAnimals > 0 && animals[ids[numAnimals - 1]].owner == msg.sender) {
					numAnimals--;
					lastId = ids[numAnimals];
					numAnimalsXType[animals[lastId].animalType]--;
					playerBalance += animals[lastId].value;
					removed[count] = lastId;
					count++;
					if (lastId == oldest) oldest = 0;
					delete animals[lastId];
				}
				//if the last animal does not belong to the player, replace the players animal by this last one
				if (numAnimals > i + 1) {
					playerBalance += animals[ids[i]].value;
					removed[count] = ids[i];
					count++;
					replaceAnimal(i);
				}
			}
		}
		newExit(msg.sender, playerBalance, removed); //fire the event to notify the client
		if (!msg.sender.send(playerBalance)) throw;
	}


	/**
	 * Replaces the animal with the given id with the last animal in the array
	 * */
	function replaceAnimal(uint16 index) internal {
		uint32 animalId = ids[index];
		numAnimalsXType[animals[animalId].animalType]--;
		numAnimals--;
		if (animalId == oldest) oldest = 0;
		delete animals[animalId];
		ids[index] = ids[numAnimals];
		delete ids[numAnimals];
	}


	/**
	 * manually triggers the attack. cannot be called afterwards, except
	 * by the owner if and only if the attack wasn't launched as supposed, signifying
	 * an error ocurred during the last invocation of oraclize, or there wasn't enough ether to pay the gas
	 * */
	function triggerAttackManually(uint32 inseconds) {
		if (!(msg.sender == owner && nextAttackTimestamp < now + 300)) throw;
		triggerAttack(inseconds, (oraclizeGas + 10000 * numAnimals));
	}

	/**
	 * sends a query to oraclize in order to get random numbers in 'inseconds' seconds
	 */
	function triggerAttack(uint32 inseconds, uint128 gasAmount) internal {
		nextAttackTimestamp = now + inseconds;
		nextAttackId = oraclize_query(nextAttackTimestamp, queryType, randomQuery, gasAmount);
	}

	/**
	 * The actual predator attack.
	 * The predator kills up to 10 animals, but in case there are less than 100 animals in the game up to 10% get eaten.
	 * */
	function __callback(bytes32 myid, string result) {
		if (msg.sender != oraclize_cbAddress() || myid != nextAttackId) throw; // just to be sure the calling address is the Oraclize authorized one and the callback is the expected one   
		uint128 pot;
		uint16 random;
		uint32 howmany = numAnimals < 100 ? (numAnimals < 10 ? 1 : numAnimals / 10) : 10; //do not kill more than 10%, but at least one
		uint16[] memory randomNumbers = getNumbersFromString(result, ",", howmany);
		uint32[] memory killedAnimals = new uint32[](howmany);
		for (uint8 i = 0; i < howmany; i++) {
			random = mapToNewRange(randomNumbers[i], numAnimals);
			killedAnimals[i] = ids[random];
			pot += killAnimal(random);
		}
		uint128 neededGas = oraclizeGas + 10000 * numAnimals;
		uint128 gasCost = uint128(neededGas * tx.gasprice);
		if (pot > gasCost)
			distribute(uint128(pot - gasCost)); //distribute the pot minus the oraclize gas costs
		triggerAttack(timeTillNextAttack(), neededGas);
		newAttack(killedAnimals);
	}

	/**
	 * the frequency of the shark attacks depends on the number of animals in the game. 
	 * many animals -> many shark attacks
	 * at least one attack in 24 hours
	 * */
	function timeTillNextAttack() constant internal returns(uint32) {
		return (86400 / (1 + numAnimals / 100));
	}


	/**
	 * kills the animal of the given type at the given index. 
	 * */
	function killAnimal(uint16 index) internal returns(uint128 animalValue) {
		animalValue = animals[ids[index]].value;
		replaceAnimal(index);
	}

	/**
	 * finds the oldest animal
	 * */
	function findOldest() {
		oldest = ids[0];
		for (uint16 i = 1; i < numAnimals; i++) {
			if (ids[i] < oldest) //the oldest animal has the lowest id
				oldest = ids[i];
		}
	}


	/** distributes the given amount among the surviving fishes*/
	function distribute(uint128 totalAmount) internal {
		//pay 10% to the oldest fish
		if (oldest == 0)
			findOldest();
		animals[oldest].value += totalAmount / 10;
		uint128 amount = totalAmount / 10 * 9;
		//distribute the rest according to their type
		uint128 valueSum;
		uint128[] memory shares = new uint128[](values.length);
		for (uint8 v = 0; v < values.length; v++) {
			if (numAnimalsXType[v] > 0) valueSum += values[v];
		}
		for (uint8 m = 0; m < values.length; m++) {
			if (numAnimalsXType[m] > 0)
				shares[m] = amount * values[m] / valueSum / numAnimalsXType[m];
		}
		for (uint16 i = 0; i < numAnimals; i++) {
			animals[ids[i]].value += shares[animals[ids[i]].animalType];
		}

	}

	/**
	 * allows the owner to collect the accumulated fees
	 * sends the given amount to the owner's address if the amount does not exceed the
	 * fees (cannot touch the players' balances) minus 100 finney (ensure that oraclize fees can be paid)
	 * */
	function collectFees(uint128 amount) {
		if (!(msg.sender == owner)) throw;
		uint collectedFees = getFees();
		if (amount + 100 finney < collectedFees) {
			if (!owner.send(amount)) throw;
		}
	}

	/**
	 * pays out the players and kills the game.
	 * */
	function stop() {
		if (!(msg.sender == owner)) throw;
		for (uint16 i = 0; i < numAnimals; i++) {
			if(!animals[ids[i]].owner.send(animals[ids[i]].value)) throw;
		}
		kill();
	}


	/**
	 * sell the animal of the given id
	 * */
	function sellAnimal(uint32 animalId) {
		if (msg.sender != animals[animalId].owner) throw;
		uint128 val = animals[animalId].value;
		uint16 animalIndex;
		for (uint16 i = 0; i < ids.length; i++) {
			if (ids[i] == animalId) {
				animalIndex = i;
				break;
			}
		}
		replaceAnimal(animalIndex);
		if (!msg.sender.send(val)) throw;
		newSell(animalId, msg.sender, val);
	}

	/** transfers animals from one contract to another.
	 *   for easier contract update.
	 * */
	function transfer(address contractAddress) {
		transferable newP4P = transferable(contractAddress);
		uint8[] memory numXType = new uint8[](costs.length);
		mapping(uint16 => uint32[]) tids;
		uint winnings;

		for (uint16 i = 0; i < numAnimals; i++) {

			if (animals[ids[i]].owner == msg.sender) {
				Animal a = animals[ids[i]];
				numXType[a.animalType]++;
				winnings += a.value - values[a.animalType];
				tids[a.animalType].push(ids[i]);
				replaceAnimal(i);
				i--;
			}
		}
		for (i = 0; i < costs.length; i++){
			if(numXType[i]>0){
				newP4P.receive.value(numXType[i]*values[i])(msg.sender, uint8(i), tids[i]);
				delete tids[i];
			}
			
		}
			
		if(winnings>0 && !msg.sender.send(winnings)) throw;
	}
	
	/**
	*	receives animals from an old contract version.
	* */
	function receive(address receiver, uint8 animalType, uint32[] oldids) payable {
		if(msg.sender!=lastP4P) throw;
		if (msg.value < oldids.length * values[animalType]) throw;
		for (uint8 i = 0; i < oldids.length; i++) {
			if (animals[oldids[i]].value == 0) {
				addAnimal(animalType, receiver, oldids[i]);
				if(oldids[i]<oldest) oldest = oldids[i];
			} else {
				addAnimal(animalType, receiver, nextId);
				nextId++;
			}
		}
		numAnimalsXType[animalType] += uint16(oldids.length);
	}

	
	
	/****************** GETTERS *************************/


	function getAnimal(uint32 animalId) constant returns(uint8, uint128, address) {
		return (animals[animalId].animalType, animals[animalId].value, animals[animalId].owner);
	}

	function get10Animals(uint16 startIndex) constant returns(uint32[10] animalIds, uint8[10] types, uint128[10] values, address[10] owners) {
		uint32 endIndex = startIndex + 10 > numAnimals ? numAnimals : startIndex + 10;
		uint8 j = 0;
		uint32 id;
		for (uint16 i = startIndex; i < endIndex; i++) {
			id = ids[i];
			animalIds[j] = id;
			types[j] = animals[id].animalType;
			values[j] = animals[id].value;
			owners[j] = animals[id].owner;
			j++;
		}

	}


	function getFees() constant returns(uint) {
		uint reserved = 0;
		for (uint16 j = 0; j < numAnimals; j++)
			reserved += animals[ids[j]].value;
		return address(this).balance - reserved;
	}


	/****************** SETTERS *************************/

	function setOraclizeGas(uint32 newGas) {
		if (!(msg.sender == owner)) throw;
		oraclizeGas = newGas;
	}

	function setMaxAnimals(uint16 number) {
		if (!(msg.sender == owner)) throw;
		maxAnimals = number;
	}
	

	/************* HELPERS ****************/

	/**
	 * maps a given number to the new range (old range 1000)
	 * */
	function mapToNewRange(uint number, uint range) constant internal returns(uint16 randomNumber) {
		return uint16(number * range / 1000);
	}

	/**
	 * converts a string of numbers being separated by a given delimiter into an array of numbers (#howmany) 
	 */
	function getNumbersFromString(string s, string delimiter, uint32 howmany) constant internal returns(uint16[] numbers) {
		strings.slice memory myresult = s.toSlice();
		strings.slice memory delim = delimiter.toSlice();
		numbers = new uint16[](howmany);
		for (uint8 i = 0; i < howmany; i++) {
			numbers[i] = uint16(parseInt(myresult.split(delim).toString()));
		}
		return numbers;
	}

}
