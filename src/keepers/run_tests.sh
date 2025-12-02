#!/bin/bash
# Quick Test Runner for OffchainValuationKeeper
# Usage: ./run_tests.sh [unit|functional|all]

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "======================================================================"
echo "OffchainValuationKeeper Test Suite"
echo "======================================================================"
echo ""

run_unit_tests() {
    echo -e "${YELLOW}Running Unit Tests...${NC}"
    echo "----------------------------------------------------------------------"
    python test_offchain_valuation_keeper.py
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Unit tests passed!${NC}"
        return 0
    else
        echo -e "${RED}❌ Unit tests failed!${NC}"
        return 1
    fi
}

run_functional_tests() {
    echo -e "${YELLOW}Running Functional Tests...${NC}"
    echo "----------------------------------------------------------------------"

    # Check if config file exists
    if [ ! -f "keeper_config_mainnet.json" ]; then
        echo -e "${RED}❌ Config file not found: keeper_config_mainnet.json${NC}"
        echo "Please provide a config file or update this script."
        return 1
    fi

    python test_keeper_functional.py --config keeper_config_mainnet.json --dry-run
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Functional tests passed!${NC}"
        return 0
    else
        echo -e "${RED}❌ Functional tests failed!${NC}"
        return 1
    fi
}

case "${1:-all}" in
    unit)
        run_unit_tests
        ;;
    functional)
        run_functional_tests
        ;;
    all)
        run_unit_tests
        UNIT_RESULT=$?
        echo ""
        run_functional_tests
        FUNCTIONAL_RESULT=$?
        echo ""
        echo "======================================================================"
        echo "Test Summary"
        echo "======================================================================"
        if [ $UNIT_RESULT -eq 0 ]; then
            echo -e "Unit Tests:       ${GREEN}✅ PASSED${NC}"
        else
            echo -e "Unit Tests:       ${RED}❌ FAILED${NC}"
        fi
        if [ $FUNCTIONAL_RESULT -eq 0 ]; then
            echo -e "Functional Tests: ${GREEN}✅ PASSED${NC}"
        else
            echo -e "Functional Tests: ${RED}❌ FAILED${NC}"
        fi
        echo ""
        if [ $UNIT_RESULT -eq 0 ] && [ $FUNCTIONAL_RESULT -eq 0 ]; then
            echo -e "${GREEN}🎉 ALL TESTS PASSED! 🎉${NC}"
            exit 0
        else
            echo -e "${RED}⚠️  SOME TESTS FAILED${NC}"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 [unit|functional|all]"
        echo ""
        echo "Options:"
        echo "  unit       - Run unit tests only (fast, no network)"
        echo "  functional - Run functional tests only (requires RPC)"
        echo "  all        - Run all tests (default)"
        exit 1
        ;;
esac
