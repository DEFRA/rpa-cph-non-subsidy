using System.ComponentModel.DataAnnotations;
using System.Text.RegularExpressions;

namespace RPA.CPH.NonSubsidy.Domain.Attributes
{
    public class PostCode : ValidationAttribute
    {
        protected override ValidationResult IsValid(object value, ValidationContext validationContext)
        {
            // A missing post code is reported by [Required]
            if (value == null)
            {
                return null;
            }

            bool flag = false;

            if (Regex.IsMatch(value.ToString(), "^([Gg][Ii][Rr] 0[Aa]{2})|((([A-Za-z][0-9]{1,2})|(([A-Za-z][A-Ha-hJ-Yj-y][0-9]{1,2})|(([A-Za-z][0-9][A-Za-z])|([A-Za-z][A-Ha-hJ-Yj-y][0-9]?[A-Za-z])))) [0-9][A-Za-z]{2})$"))
            {
                flag = true;
            }

            if (!flag)
            {
                ValidationResult result = new ValidationResult("Invalid Post Code.");

                return result;
            }
            else
            {
                return null;
            }
        }
    }
}

