pragma solidity 0.5.12;

import "@etherisc/gif-contracts/contracts/services/InstanceOperatorService.sol";
import "@etherisc/gif-contracts/contracts/Product.sol";

contract FlightDelayEtheriscOracle is Product {

    // Dec 2020. This version is oracle agnostic i.e. it will work with Chainlink, Oraclize, ...

    bytes32 public constant NAME = "FlightDelaySokol";
    bytes32 public constant VERSION = "0.1.0";
    bytes32 public constant XDAI = "XDAI";
    uint256 public constant ETHERISC_ORACLE_ID = 0;

    event LogRequestFlightStatistics(
        uint256 requestId,
        bytes32 carrierFlightNumber,
        uint256 departureTime,
        uint256 arrivalTime
    );

    event LogRequestFlightStatus(
        uint256 requestId,
        bytes32 carrierFlightNumber,
        uint256 arrivalTime
    );

    event LogRequestPayout(
        uint256 policyId,
        uint256 claimId,
        uint256 payoutId,
        uint256 amount
    );

    event LogError(string error);

    event LogUnprocessableStatus(uint256 requestId, uint256 policyId);

    event LogPolicyExpired(uint256 policyId);

    event LogRequestPayment(uint256 requestId, uint256 applicationId);

    event LogUnexpectedStatus(uint256 requestId, bytes1 status, int256 delay);

    bytes32 public constant POLICY_FLOW = "PolicyFlowDefault";

    // Minimum observations for valid prediction
    uint256 public constant MIN_OBSERVATIONS = 10;
    // Minimum time before departure for applying
    uint256 public constant MIN_TIME_BEFORE_DEPARTURE = 24 hours;
    // Maximum duration of flight
    uint256 public constant MAX_FLIGHT_DURATION = 2 days;
    // Check for delay after .. minutes after scheduled arrival
    uint256 public constant CHECK_OFFSET = 3 hours;

    // All amounts expected to be provided in a currency’s smallest unit
    // E.g. 10 EUR = 1000 (1000 cents)
    uint256 public constant MIN_PREMIUM =  1500; // USD  15.00
    uint256 public constant MAX_PREMIUM =  2500; // USD  25.00
    uint256 public constant MAX_PAYOUT  = 75000; // USD 750.00

    // ['observations','late15','late30','late45','cancelled','diverted']
    uint8[6] public weightPattern = [0, 0, 0, 30, 50, 50];

    // Maximum cumulated weighted premium per risk
    uint256 constant MAX_CUMULATED_WEIGHTED_PREMIUM = 6000000;

    struct Risk {
        bytes32 carrierFlightNumber;
        bytes32 departureYearMonthDay;
        uint256 departureTime;
        uint256 arrivalTime;
        uint delayInMinutes;
        uint8 delay;
        uint256 cumulatedWeightedPremium;
        uint256 premiumMultiplier;
        uint256 weight;
    }

    struct RequestMetadata {
        uint256 applicationId;
        uint256 policyId;
        bytes32 riskId;
    }

    mapping(bytes32 => Risk) public risks;

    mapping(uint256 => RequestMetadata) public oracleRequests;

    constructor(address _productController)
        public
        Product(_productController, NAME, POLICY_FLOW)
    {}

    function applyForPolicy (
        // domain specific
        bytes32 _carrierFlightNumber,
        bytes32 _departureYearMonthDay,
        uint256 _departureTime,
        uint256 _arrivalTime,
        uint256[] calldata _payoutOptions
    ) external payable {
        // Validate input parameters
        uint256 premium = msg.value;
        require(premium >= MIN_PREMIUM, "ERROR::INVALID_PREMIUM");
        require(premium <= MAX_PREMIUM, "ERROR::INVALID_PREMIUM");
        require(
            _arrivalTime > _departureTime,
            "ERROR::INVALID_ARRIVAL/DEPARTURE_TIME"
        );
        require(
            _arrivalTime <= _departureTime + MAX_FLIGHT_DURATION,
            "ERROR::INVALID_ARRIVAL/DEPARTURE_TIME"
        );
        require(
            _departureTime >= block.timestamp + MIN_TIME_BEFORE_DEPARTURE,
            "ERROR::TIME_TO_DEPARTURE_TOO_SMALL"
        );

        bytes32 bpExternalKey = keccak256(msg.sender);
        // Create risk if not exists
        bytes32 riskId = keccak256(
            abi.encodePacked(_carrierFlightNumber, _departureTime, _arrivalTime)
        );
        Risk storage risk = risks[riskId];

        if (risk.carrierFlightNumber == "") {
            risk.carrierFlightNumber = _carrierFlightNumber;
            risk.departureYearMonthDay = _departureYearMonthDay;
            risk.departureTime = _departureTime;
            risk.arrivalTime = _arrivalTime;
        }

        if (premium * risk.premiumMultiplier + risk.cumulatedWeightedPremium >= MAX_CUMULATED_WEIGHTED_PREMIUM) {
            emit LogError("ERROR::CLUSTER_RISK");
            return;
        }

        if (risk.cumulatedWeightedPremium == 0) {
            risk.cumulatedWeightedPremium = MAX_CUMULATED_WEIGHTED_PREMIUM;
        }

        // Create new application
        uint256 applicationId = _newApplication(
            bpExternalKey,
            premium,
            XDAI,
            _payoutOptions
        );

        // Request flight ratings
        uint256 requestId = _request(
            abi.encode(_carrierFlightNumber),
            "flightStatisticsCallback",
            "FlightRatings",
            ETHERISC_ORACLE_ID // Oracle Id
        );

        oracleRequests[requestId].applicationId = applicationId;
        oracleRequests[requestId].riskId = riskId;

        emit LogRequestFlightStatistics(
            requestId,
            _carrierFlightNumber,
            _departureTime,
            _arrivalTime
        );
    }

    function flightStatisticsCallback(
        uint256 _requestId,
        bytes calldata _response
    ) external onlyOracle {
        // Statistics: ['observations','late15','late30','late45','cancelled','diverted']
        uint256[6] memory _statistics = abi.decode(_response, (uint256[6]));

        uint256 applicationId = oracleRequests[_requestId].applicationId;

        if (_statistics[0] <= MIN_OBSERVATIONS) {
            _decline(applicationId);
            return;
        }

        uint256 premium = _getPremium(applicationId);
        uint256[] memory payoutOptions = _getPayoutOptions(applicationId);
        (uint256 weight, uint256[5] memory calculatedPayouts) = calculatePayouts(
            premium,
            _statistics
        );

        if (payoutOptions.length != calculatedPayouts.length) {
            emit LogError("ERROR::INVALID_PAYOUT_OPTIONS_COUNT");
            return;
        }

        for (uint256 i = 0; i < 5; i++) {
            if (payoutOptions[i] != calculatedPayouts[i]) {
                emit LogError("ERROR::INVALID_PAYOUT_OPTION");
                return;
            }

            if (payoutOptions[i] > MAX_PAYOUT) {
                emit LogError("ERROR::PAYOUT>MAX_PAYOUT");
                return;
            }
        }

        bytes32 riskId = oracleRequests[_requestId].riskId;

        if (risks[riskId].premiumMultiplier == 0) {
            // It's the first policy for this risk, we accept any premium
            risks[riskId].cumulatedWeightedPremium = premium * 100000 / weight;
            risks[riskId].premiumMultiplier = 100000 / weight;
        } else {
            uint256 cumulatedWeightedPremium = premium * risks[riskId].premiumMultiplier;

            if (cumulatedWeightedPremium > MAX_PAYOUT) {
                cumulatedWeightedPremium = MAX_PAYOUT;
            }

            risks[riskId].cumulatedWeightedPremium = risks[riskId].cumulatedWeightedPremium + cumulatedWeightedPremium;
        }

        risks[riskId].weight = weight;

        uint256 policyId = _underwrite(applicationId);

        // Request flight statuses
        uint256 requestId = _request(
            abi.encode(
                risks[riskId].arrivalTime + CHECK_OFFSET,
                risks[riskId].carrierFlightNumber,
                risks[riskId].departureYearMonthDay
            ),
            "flightStatusCallback",
            "FlightStatuses",
            1
        );

        oracleRequests[requestId] = RequestMetadata(
            applicationId,
            policyId,
            riskId
        );

        emit LogRequestFlightStatus(
            requestId,
            risks[riskId].carrierFlightNumber,
            risks[riskId].arrivalTime
        );
    }

    function flightStatusCallback(uint256 _requestId, bytes calldata _response)
        external
        onlyOracle
    {
        (bytes1 status, int256 delay) = abi.decode(_response, (bytes1, int256));

        uint256 policyId = oracleRequests[_requestId].policyId;
        uint256 applicationId = oracleRequests[_requestId].applicationId;
        uint256[] memory payoutOptions = _getPayoutOptions(applicationId);

        if (status != "L" && status != "A" && status != "C" && status != "D") {
            emit LogUnprocessableStatus(_requestId, policyId);
            return;
        }

        if (status == "A") {
            // todo: active, reschedule oracle call + 45 min
            emit LogUnexpectedStatus(_requestId, status, delay);
            return;
        }

        if (status == "C") {
            resolvePayout(policyId, payoutOptions[3]);
        } else if (status == "D") {
            resolvePayout(policyId, payoutOptions[4]);
        } else if (delay >= 15 && delay < 30) {
            resolvePayout(policyId, payoutOptions[0]);
        } else if (delay >= 30 && delay < 45) {
            resolvePayout(policyId, payoutOptions[1]);
        } else if (delay >= 45) {
            resolvePayout(policyId, payoutOptions[2]);
        } else {
            resolvePayout(policyId, 0);
        }
    }

    function resolvePayout(uint256 _policyId, uint256 _payoutAmount) internal {
        if (_payoutAmount == 0) {
            _expire(_policyId);

            emit LogPolicyExpired(_policyId);
        } else {
            uint256 claimId = _newClaim(_policyId);
            uint256 payoutId = _confirmClaim(claimId, _payoutAmount);
            _payout(_payoutId, _payoutAmount);
        }
    }

    function calculatePayouts(uint256 _premium, uint256[6] memory _statistics)
        public
        view
        returns (uint256 _weight, uint256[5] memory _payoutOptions)
    {
        require(_premium >= MIN_PREMIUM, "ERROR::INVALID_PREMIUM");
        require(_premium <= MAX_PREMIUM, "ERROR::INVALID_PREMIUM");
        require(_statistics[0] > MIN_OBSERVATIONS, "ERROR::LOW_OBSERVATIONS");

        _weight = 0;
        _payoutOptions = [uint256(0), 0, 0, 0, 0];

        for (uint256 i = 1; i < 6; i++) {
            _weight += weightPattern[i] * _statistics[i] * 10000 / _statistics[0];
            // 1% = 100 / 100% = 10,000
        }

        // To avoid div0 in the payout section, we have to make a minimal assumption on weight
        if (_weight == 0) {
            _weight = 100000 / _statistics[0];
        }

        for (uint256 i = 0; i < 5; i++) {
            _payoutOptions[i] = _premium * weightPattern[i + 1] * 10000 / _weight;

            if (_payoutOptions[i] > MAX_PAYOUT) {
                _payoutOptions[i] = MAX_PAYOUT;
            }
        }
    }

}
