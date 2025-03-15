// src/utils/feeUtils.js

// Global platform fee rate (2%)
const PLATFORM_FEE_RATE = 0.02;

/**
 * Calculate platform fee and assign responsibility based on transaction type.
 * @param {number} amount - Transaction amount
 * @param {string} transactionType - Type of transaction ('purchase', 'deposit', 'transfer')
 * @returns {object} - Object containing responsible party, platform fee, total amount
 */
export const calculatePlatformFee = (amount, transactionType = 'purchase') => {
  // Ensure amount is a valid number, default to 0 if invalid
  const validAmount = parseFloat(amount) || 0;

  // No fee on deposits
  if (transactionType === 'deposit') {
    return {
      responsibleParty: null, // No fee applied
      platformFee: 0,
      totalAmount: validAmount,
    };
  }

  const platformFee = validAmount * PLATFORM_FEE_RATE;
  const totalAmount = validAmount + platformFee;

  // Error handling for invalid calculations
  if (isNaN(platformFee) || isNaN(totalAmount)) {
    throw new Error('Invalid amount: Could not calculate platform fee or total amount.');
  }

  // Assign fee responsibility
  let responsibleParty;
  switch (transactionType) {
    case 'purchase':
      responsibleParty = 'buyer'; // Buyers pay fees for purchases
      break;
    case 'transfer':
      responsibleParty = 'recipient'; // Recipients pay fees for transfers
      break;
    default:
      throw new Error('Unsupported transaction type');
  }

  return {
    responsibleParty,
    platformFee,
    totalAmount, // Corrected total amount including fees
  };
};
